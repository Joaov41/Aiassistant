import SwiftUI
import MarkdownUI // Make sure this package is added to your project and imported

// MARK: - Data Model for Chat Messages

// Ensure this struct is defined ONLY ONCE, in this file (ResponseView.swift).
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String // "user" or "assistant"
    let content: String
    let images: [Data] // Ensure Data is known (Foundation)
    let providerName: String?
    let timestamp: Date = Date()

    init(role: String, content: String, images: [Data] = [], providerName: String? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.providerName = providerName
    }

    // Equatable conformance
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id // ID is enough for identity in this context
    }
}

// MARK: - View Model for ResponseView Logic

// Ensure this class is defined ONLY ONCE, in this file (ResponseView.swift).
final class ResponseViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var fontSize: CGFloat = 14
    @Published var showCopyConfirmation: Bool = false
    @Published var isProcessingFollowUp: Bool = false // Track follow-up state

    let initialSelectedText: String
    let initialOption: WritingOption // Ensure WritingOption enum is defined and accessible
    private var pccTranscriptName: String?

    // Keep a weak reference to the AppState singleton
    private weak var appStateRef: AppState?
    
    // Add a dedicated cancellation token for cleanup
    private var cancellationTask: Task<Void, Never>?
    
    deinit {
        print("🗑️ ResponseViewModel deinit")
        // Cancel any pending tasks
        cancellationTask?.cancel()
    }

    init(
        content: String,
        selectedText: String,
        option: WritingOption,
        images: [Data] = [],
        providerName: String,
        pccTranscriptName: String?
    ) {
        self.initialSelectedText = selectedText
        self.initialOption = option
        self.pccTranscriptName = pccTranscriptName
        self.appStateRef = AppState.shared

        // Debug log to check initialSelectedText content
        print("DEBUG: Initializing ResponseViewModel. initialSelectedText length: \(selectedText.count)")
        if selectedText.count > 100 {
            let snippet = selectedText.prefix(100)
            print("DEBUG: initialSelectedText snippet: \(snippet)...")
        } else {
            print("DEBUG: initialSelectedText: \(selectedText)")
        }

        // Initialize with the first assistant message
        self.messages.append(ChatMessage(
            role: "assistant",
            content: content,
            images: images,
            providerName: providerName
        ))
        print("ResponseViewModel initialized.")
    }

    func processFollowUpQuestion(_ question: String, completion: @escaping () -> Void) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            completion()
            return
        }

        let userMessage = ChatMessage(role: "user", content: trimmedQuestion)
        var promptMessages: [ChatMessage] = []
        self.messages.append(userMessage)
        self.isProcessingFollowUp = true
        promptMessages = self.messages

        // Cancel any previous task
        cancellationTask?.cancel()
        
        // Create a new task
        cancellationTask = Task { [weak self] in
            guard let self = self,
                  let appState = self.appStateRef else {
                await MainActor.run {
                    completion()
                }
                return
            }
            
            do {
                // Build conversation history
                let conversationHistory = promptMessages.map { msg in
                    "\(msg.role.capitalized): \(msg.content)"
                }.joined(separator: "\n\n")
                let originalContext = self.initialSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                let backgroundContext = originalContext.isEmpty
                    ? ""
                    : """

                    Secondary background context from the original selection, if relevant. Ignore this if it conflicts with the chat transcript:
                    ---
                    \(originalContext)
                    ---
                    """
                
                let combinedPrompt = """
                VERY IMPORTANT: Respond based on the chat transcript first. DO NOT generate or edit images.
                Answer the latest User message directly.
                Resolve pronouns like "it", "that", and "this" from the immediately preceding assistant/user messages.
                If the latest question refers to the prior answer, do not search the secondary background for unrelated dates or entities.

                Chat transcript:
                ---
                \(conversationHistory)
                ---
                Latest User message:
                \(trimmedQuestion)
                \(backgroundContext)
                """

                // Debug log full conversation history length
                print("DEBUG: Full conversationHistory length: \(conversationHistory.count)")

                let response: AIResponse
                if AppSettings.shared.selectedAIProvider == .applePCC,
                   let transcriptName = self.pccTranscriptName,
                   originalContext.isEmpty {
                    response = try await appState.pccProvider.processText(
                        systemPrompt: nil,
                        userPrompt: trimmedQuestion,
                        images: [],
                        videos: [],
                        transcriptName: transcriptName
                    )
                } else {
                    let strictSystemPrompt = originalContext.isEmpty ? self.initialOption.systemPrompt : """
                    You are a precise document extraction assistant. Use only the provided document/background context and chat transcript.
                    If an amount, currency, date, or field is not explicitly present, say it is not found.
                    Do not infer subtotals, taxes, totals, conversions, or missing values unless the user explicitly asks you to calculate from listed amounts.
                    """
                    response = try await appState.processWithActiveProvider(
                        systemPrompt: strictSystemPrompt,
                        userPrompt: combinedPrompt,
                        images: [],
                        videos: []
                    )
                }
                if let updatedTranscriptName = response.pccTranscriptName {
                    self.pccTranscriptName = updatedTranscriptName
                }

                let assistantMessage = ChatMessage(
                    role: "assistant",
                    content: response.text,
                    images: response.images,
                    providerName: response.providerName
                )

                // Check if task was cancelled
                if Task.isCancelled {
                    print("Follow-up task was cancelled")
                    await MainActor.run {
                        self.isProcessingFollowUp = false
                        completion()
                    }
                    return
                }

                // Update UI on main thread
                await MainActor.run {
                    guard !Task.isCancelled else { 
                        self.isProcessingFollowUp = false
                        completion()
                        return 
                    }
                    self.messages.append(assistantMessage)
                    self.isProcessingFollowUp = false
                    completion()
                    print("Follow-up processed.")
                }
            } catch {
                if Task.isCancelled {
                    print("Follow-up task was cancelled during error handling")
                    await MainActor.run {
                        self.isProcessingFollowUp = false
                        completion()
                    }
                    return
                }
                
                let errorMessage = "Error processing follow-up: \(error.localizedDescription)"
                let errorChatMessage = ChatMessage(role: "assistant", content: errorMessage)
                print(errorMessage)
                
                // Update UI on main thread
                await MainActor.run {
                    guard !Task.isCancelled else { 
                        self.isProcessingFollowUp = false
                        completion()
                        return 
                    }
                    self.messages.append(errorChatMessage)
                    self.isProcessingFollowUp = false
                    completion()
                }
            }
        }
    }

    func clearConversation() {
        // Keep only the initial assistant message if needed, or clear all
        if let firstMessage = messages.first, firstMessage.role == "assistant" {
            messages = [firstMessage]
        } else {
            messages.removeAll()
        }
        print("ResponseViewModel conversation cleared/reset.")
    }

    func copyContent() {
        // Concatenate all assistant messages for copying
        let conversationText = messages.filter { $0.role == "assistant" }
                                       .map { $0.content }
                                       .joined(separator: "\n\n---\n\n") // Separator between messages

        if conversationText.isEmpty { return }

        // Ensure NSPasteboard is known (AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conversationText, forType: .string)

        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.showCopyConfirmation = false
        }
        print("Assistant content copied.")
    }
}


// MARK: - Main Response View

// Ensure this struct is defined ONLY ONCE, in this file (ResponseView.swift).
struct ResponseView: View {
    // Use @StateObject because ResponseView *owns* this specific instance of the ViewModel
    @StateObject private var viewModel: ResponseViewModel
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("use_gradient_theme") private var useGradientTheme = false
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariantRaw: Int = 11
    @State private var inputText: String = ""
    
    // New property for top inset (for title bar space)
    var contentTopInset: CGFloat = 0
    
    // Public method to check if this view contains images
    var hasImages: Bool {
        return viewModel.messages.first?.images.isEmpty == false
    }

    // Initializer to create the ViewModel
    init(
        content: String,
        selectedText: String,
        option: WritingOption,
        images: [Data] = [],
        providerName: String,
        pccTranscriptName: String? = nil,
        contentTopInset: CGFloat = 0
    ) {
        // Create the ViewModel instance here and assign it to the @StateObject wrapper
        self._viewModel = StateObject(wrappedValue: ResponseViewModel(
            content: content,
            selectedText: selectedText,
            option: option,
            images: images,
            providerName: providerName,
            pccTranscriptName: pccTranscriptName
        ))
        self.contentTopInset = contentTopInset
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
                    // Background gradient to match the quick actions window
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
            
            VStack(spacing: 0) {
                // Add spacing for the title bar if needed
                if contentTopInset > 0 {
                    Spacer()
                        .frame(height: contentTopInset)
                }
                
                // Top toolbar
                HStack {
                    Button(action: { viewModel.copyContent() }) {
                        Label(viewModel.showCopyConfirmation ? "Copied!" : "Copy Response",
                              systemImage: viewModel.showCopyConfirmation ? "checkmark" : "doc.on.doc")
                    }
                    .glassButtonStyle(variant: .v8)
                    .animation(.easeInOut, value: viewModel.showCopyConfirmation)
                    .help("Copy assistant's responses to clipboard")

                    Spacer()

                    HStack(spacing: 8) {
                        Button(action: { viewModel.fontSize = max(10, viewModel.fontSize - 2) }) {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .glassButtonStyle(variant: .v8)
                        .disabled(viewModel.fontSize <= 10)
                        .help("Decrease font size")

                        Button(action: { viewModel.fontSize = 14 }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .glassButtonStyle(variant: .v8)
                        .help("Reset font size")

                        Button(action: { viewModel.fontSize = min(24, viewModel.fontSize + 2) }) {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .glassButtonStyle(variant: .v8)
                        .disabled(viewModel.fontSize >= 24)
                        .help("Increase font size")
                    }
                }
                .padding()

                // Chat messages area
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) { // Ensure alignment is leading
                            ForEach(viewModel.messages) { message in
                                ChatMessageView(message: message, fontSize: viewModel.fontSize) // Ensure ChatMessageView is defined
                                    .id(message.id) // Assign ID for scrolling
                                    .padding(.horizontal) // Add horizontal padding to messages
                            }
                            // Show typing indicator if processing follow-up
                            if viewModel.isProcessingFollowUp {
                                 HStack {
                                     ProgressView()
                                         .progressViewStyle(.circular)
                                         .scaleEffect(0.6)
                                         .tint(Color.white.opacity(0.8))
                                     Text("Assistant is thinking...")
                                         .font(.caption)
                                         .fontWeight(.semibold)
                                         .foregroundColor(.white.opacity(0.8))
                                     Spacer() // Pushes indicator left
                                 }
                                 .padding(.horizontal)
                                 .padding(.top, 8)
                                 .id("typingIndicator") // Give indicator an ID if needed for scrolling
                            }
                        }
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in // Use count for reliable trigger
                        // Scroll to bottom when message count changes
                        let lastId = viewModel.isProcessingFollowUp ? "typingIndicator" : viewModel.messages.last?.id as (any Hashable)?
                        if let idToScroll = lastId {
                            proxy.scrollTo(idToScroll, anchor: .bottom)
                        }
                    }
                }

                // Input area
                VStack(spacing: 0) { // Use zero spacing for tight layout
                    Divider()
                        .background(Color.gray.opacity(0.3))

                    HStack(spacing: 8) {
                        TextField("Ask a follow-up question...", text: $inputText, axis: .vertical) // Allow vertical expansion
                            .textFieldStyle(.plain)
                            .lineLimit(1...5) // Allow up to 5 lines
                            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)) // Adjust padding
                            .background(Color.black.opacity(0.15)
                                .overlay(.ultraThinMaterial.opacity(0.7))
                                .overlay(Color.black.opacity(0.05)))
                            .cornerRadius(8)
                            .onSubmit(sendMessage) // Send on Return key
                            .disabled(viewModel.isProcessingFollowUp) // Disable while processing
                            .foregroundColor(.white.opacity(0.9))

                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                                .symbolRenderingMode(.multicolor)
                        }
                        .glassButtonStyle(variant: .v10, cornerRadius: 12)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessingFollowUp) // Disable if empty or processing
                        .keyboardShortcut(.return, modifiers: []) // Allow sending with Enter
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.15))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
        .preferredColorScheme(.dark)
        .edgesIgnoringSafeArea(.bottom) // Allow input bar to touch bottom edge potentially
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        inputText = "" // Clear input field
        viewModel.processFollowUpQuestion(question) {
            // Optional: Completion handler logic after processing finishes
            print("Follow-up completion handler called.")
        }
    }
}

// MARK: - Individual Chat Message View

// Ensure this struct is defined ONLY ONCE, likely within this file (ResponseView.swift).
struct ChatMessageView: View {
    let message: ChatMessage
    let fontSize: CGFloat
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariantRaw: Int = 11
    
    // Use the same translucent material background as in other views
    var messageBackground: some View {
        Group {
            if themeStyle == "glass" {
                LiquidGlassBackground(
                    variant: GlassVariant(rawValue: glassVariantRaw) ?? .v11,
                    cornerRadius: 15
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
        HStack(alignment: .bottom, spacing: 8) { // Align to bottom for icon consistency
            // Assistant icon on the left
            if message.role == "assistant" {
                Image(systemName: "sparkles.circle.fill") // Filled icon example
                    .font(.title3) // Slightly smaller icon
                    .foregroundColor(.accentColor)
                    .padding(.bottom, 5) // Align with bottom of bubble
            } else {
                 Spacer().frame(width: 30) // Placeholder to push user message right
            }

            // Bubble content
            VStack(alignment: message.role == "assistant" ? .leading : .trailing, spacing: 4) {
                // Content (Text and Images)
                VStack(alignment: .leading, spacing: 8) {
                    if message.role == "assistant", let providerName = message.providerName {
                        Label(providerName, systemImage: providerName.contains("PCC") ? "cloud" : "apple.intelligence")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(providerName.contains("PCC") ? .cyan.opacity(0.9) : .green.opacity(0.9))
                            .padding(.bottom, 2)
                            .help("This response was generated with \(providerName)")
                    }

                    // Render Markdown text
                    Markdown(message.content)
                        .markdownTheme(.basic) // Use basic theme without backgrounds
                        .markdownTextStyle {
                             FontSize(fontSize) // Apply dynamic font size
                             ForegroundColor(.white.opacity(0.9)) // Use white with opacity for consistency
                             FontWeight(.bold) // Make text bold
                        }
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            configuration.label
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion

                    // Display Images
                    if !message.images.isEmpty {
                         ForEach(0..<message.images.count, id: \.self) { index in
                             // Ensure NSImage is known (AppKit)
                             if let nsImage = NSImage(data: message.images[index]) {
                                 Image(nsImage: nsImage)
                                     .resizable()
                                     .aspectRatio(contentMode: .fit)
                                     .frame(maxWidth: 350, maxHeight: 350) // Limit image size
                                     .cornerRadius(8)
                                     .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                     .padding(.top, 5)
                             }
                         }
                    }
                }
                .frame(maxWidth: 550, alignment: message.role == "assistant" ? .leading : .trailing) // Limit bubble width slightly more

                // Timestamp below the bubble
                Text(message.timestamp.formatted(.dateTime.hour().minute()))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 5) // Padding for timestamp
            }


            // User icon on the right
            if message.role == "user" {
                 Image(systemName: "person.circle.fill") // Filled icon example
                     .font(.title3) // Slightly smaller icon
                     .foregroundColor(.white.opacity(0.8))
                     .padding(.bottom, 5) // Align with bottom of bubble
            } else {
                 Spacer().frame(width: 30) // Placeholder to push assistant message left
            }
        }
    }

    // Helper for bubble background color
    @ViewBuilder
    private func bubbleBackground(for role: String) -> some View {
        if role == "user" {
            messageBackground.opacity(1.2) // Slightly stronger for user messages
        } else {
            messageBackground
        }
    }
}

// Make sure you have WindowBackground ViewModifier defined in BackgroundModifier.swift
// and the extension to apply it easily:
/*
extension View {
    func windowBackground(useGradient: Bool) -> some View {
        modifier(WindowBackground(useGradient: useGradient))
    }
}
*/
