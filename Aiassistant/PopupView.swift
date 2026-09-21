import SwiftUI
import Cocoa  // For CGEvent and related APIs
import MarkdownUI  // Add this import
import UniformTypeIdentifiers

struct PopupView: View {
    @ObservedObject var appState: AppState
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariantRaw: Int = 0
    
    // Local chat state for the conversation with unique IDs and image support
    @StateObject private var conversation = ConversationController()
    @State private var userInput: String = ""
    @State private var selectedReplyMessageID: UUID?
    @State private var selectedReplyText: String = ""
    @State private var replyTextHeights: [UUID: CGFloat] = [:]
    
    // Track the most recently generated image for editing requests
    @State private var lastGeneratedImage: Data? = nil

    // Show Quick Actions menu for rewrite mode
    @State private var showQuickActions = false
    
    // Track whether we are calling the AI
    private var isProcessing: Bool {
        conversation.isProcessing || appState.isProcessing || appState.isAttachmentLoading
    }
    
    // Store the application that was active when our popup appeared
    @State private var targetApplication: NSRunningApplication?
    
    // Removed local InteractionMode; now using AppState.InteractionMode everywhere
    
    // --- ADDED: Alert state for screenshot errors ---
    @State private var showPermissionAlert: Bool = false
    @State private var showCaptureErrorAlert: Bool = false
    // -------------------------------------------------
    @State private var isDropTargeted: Bool = false
    @State private var dropFeedback: String? = nil
    @State private var lastDropFeedbackID: UUID?
    @State private var attachmentMessageID: UUID?
    @State private var showAttachmentPreview = false
    @State private var dragOffset: CGFloat = 0
    
    private var dropTypes: [UTType] {
        var types: [UTType] = [
            .fileURL,
            .image,
            .pdf,
            .movie,
            .url,
            .plainText,
            .utf8PlainText,
            .utf16PlainText,
            .text
        ]
        for identifier in emailTypeIdentifiers {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        if let emlType = UTType(filenameExtension: "eml") {
            types.append(emlType)
        }
        return types
    }
    
    private let emailTypeIdentifiers = [
        "com.apple.mail.email",
        "public.message"
    ]
    
    var messageBackground: some View {
        Group {
            if themeStyle == "glass" {
                LiquidGlassBackground(
                    variant: GlassVariant(rawValue: glassVariantRaw) ?? .regular, 
                    cornerRadius: 12
                ) {
                    Color.clear
                }
            } else {
                Color.clear.overlay(.ultraThinMaterial.opacity(0.3))
            }
        }
    }
    
    // --- ADDED: Extracted view for chat/input UI ---
    // --- REFACTORED: Broke down chatAndInputView further ---
    
    // Sub-view for the scrollable chat messages
    @ViewBuilder
    private var chatMessagesScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(conversation.messages, id: \.id) { item in
                    let msg = item.message
                    if msg.hasPrefix("User: ") {
                        Text(msg)
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity, alignment: .leading)
	                    } else if msg.hasPrefix("Assistant: ") {
	                        let response = msg.replacingOccurrences(of: "Assistant: ", with: "")
	                        VStack(alignment: .leading, spacing: 8) {
                            // Text content
		                            ZStack(alignment: .topTrailing) {
		                                AssistantMarkdownReplyView(
		                                    text: response,
		                                    onSelectionChange: { selection in
		                                        selectedReplyMessageID = selection.isEmpty ? nil : item.id
		                                        selectedReplyText = selection
		                                    }
		                                )
		                                
		                                if selectedReplyMessageID == item.id && !selectedReplyText.isEmpty {
		                                    Button("Ask") {
		                                        userInput = """
		                                        About this selected part:
		                                        "\(selectedReplyText)"
		                                        """
		                                        selectedReplyMessageID = nil
		                                        selectedReplyText = ""
		                                    }
		                                    .font(.caption)
		                                    .glassButtonStyle(variant: .regular)
		                                    .padding(.top, 4)
		                                    .padding(.trailing, 4)
		                                    .help("Use the selected reply text as context for your next question")
		                                }
		                            }
		                            .padding(.bottom, !item.images.isEmpty ? 8 : 0)
                            
                            // Display images if present
                            if !item.images.isEmpty {
                                ForEach(0..<item.images.count, id: \.self) { index in
                                    let imageData = item.images[index]
                                    VStack(spacing: 8) {
                                        if let nsImage = NSImage(data: imageData) {
                                            ZStack(alignment: .topTrailing) {
                                                Image(nsImage: nsImage)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .frame(maxWidth: 300, maxHeight: 300)
                                                    .cornerRadius(8)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                                    )
                                                    .shadow(radius: 2)
                                                
                                                Button(action: {
                                                    saveImage(imageData)
                                                }) {
                                                    Image(systemName: "square.and.arrow.down")
                                                        .foregroundColor(.white)
                                                        .padding(8)
                                                        .background(Color.black.opacity(0.7))
                                                        .clipShape(Circle())
                                                }
                                                .glassButtonStyle(variant: .regular, cornerRadius: 15)
                                                .padding(8)
                                                .scaleEffect(1.2)
                                            }
                                        } else {
                                            Text("Image could not be displayed")
                                                .fontWeight(.bold)
                                                .foregroundColor(.red)
                                                .padding()
                                                .frame(maxWidth: .infinity)
                                                .background(Color.gray.opacity(0.1))
                                                .cornerRadius(8)
                                        }
                                        
                                        Text("Generated Image")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.secondary)
                                        
                                        Button("Save Image") {
                                            saveImage(imageData)
                                        }
                                        .font(.caption)
                                        .glassButtonStyle(variant: .regular)
                                        
                                        if item.id == conversation.messages.last?.id && item.images.contains(where: { $0 == lastGeneratedImage }) {
                                            Text("Tip: You can request changes to this image")
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 2)
                                            
                                            Button("Modify This Image") {
                                                userInput = "Create a new version of this image but with: "
                                                // Focus the text input
                                                NSApp.keyWindow?.makeFirstResponder(nil)
                                            }
                                            .font(.caption)
                                            .glassButtonStyle(variant: .regular)
                                            .padding(.top, 4)
                                            .help("The AI will describe changes to this image based on your request")
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(msg)
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Sub-view for the bottom input controls area
    @ViewBuilder
    private var inputAreaView: some View {
        VStack(spacing: 0) {
            Divider()
                .background(.secondary)
            
            // Mode Picker: Chat vs. Rewrite in Place
            HStack(spacing: 12) {
                Button(action: { appState.selectedMode = .chat }) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(variant: .regular)
                .opacity(appState.selectedMode == .chat ? 1.0 : 0.6)
                
                Button(action: { appState.selectedMode = .rewrite }) {
                    Label("Rewrite", systemImage: "pencil.line")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(variant: .regular)
                .opacity(appState.selectedMode == .rewrite ? 1.0 : 0.6)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Instructions for Rewrite mode
            if appState.selectedMode == .rewrite {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How to use Rewrite:")
                        .fontWeight(.medium)
                    Text("1. Select text in any application")
                    Text("2. Type rewrite instructions below or use a custom prompt")
                    Text("3. Press Send to replace the text")
                    Button(action: { showQuickActions = true }) {
                        HStack {
                            Image(systemName: "bolt.fill")
                            Text("Choose Custom Prompt")
                        }
                    }
                    .padding(.top, 6)
                    .glassButtonStyle(variant: .regular)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
            
            // Input area with modern styling
            HStack(spacing: 12) {
                TextField(appState.selectedMode == .rewrite ? "Type rewrite instructions..." : "Type your message...", 
                         text: $userInput)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .onSubmit { onSend() }
                    .disabled(isProcessing)
                
                if isProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                }
                
                Button(action: onSend) {
                    Text(appState.selectedMode == .rewrite ? "Rewrite" : "Send")
                        .fontWeight(.medium)
                }
                .glassButtonStyle(variant: .regular)
                .disabled(isProcessing || userInput.isEmpty)
            }
            .padding()
            
        // Bottom row: New Chat button with modern styling
        HStack {
            Button(action: startNewChat) {
                Label("New Chat", systemImage: "plus.message")
            }
            .glassButtonStyle(variant: .regular)
            .padding(.leading, 12)
            
            Spacer()
            
            Button(action: {
                appState.updateRunningApplications()
                appState.isSelectingAppForCapture = true
            }) {
                Label("Capture Window", systemImage: "rectangle.on.rectangle")
            }
            .glassButtonStyle(variant: .regular)
            .help("Capture a screenshot from another application window")
            
            Spacer()
            
            Button(action: copyChatToClipboard) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .glassButtonStyle(variant: .regular)
            .padding(.trailing, 12)
        }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var attachedContentView: some View {
        let previewImageData = appState.capturedScreenshotData ?? appState.selectedImages.first
        let attachmentName = appState.attachedContentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = attachmentName?.isEmpty == false ? attachmentName ?? "Captured Window" : "Captured Window"

        if previewImageData != nil || attachmentName?.isEmpty == false {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    if let previewImageData, let nsImage = NSImage(data: previewImageData) {
                        Button {
                            showAttachmentPreview = true
                        } label: {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 36)
                                .clipped()
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                                )
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .help("Open attachment preview")
                    } else {
                        Image(systemName: "paperclip")
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                    }

                    Text(displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    if previewImageData != nil {
                        Button {
                            showAttachmentPreview = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open attachment preview")
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // Combined chat/input view (using the sub-views)
    @ViewBuilder
    private var chatAndInputView: some View {
        VStack(spacing: 0) {
            if appState.isProcessing && appState.capturedScreenshotData == nil && appState.selectedImages.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Capturing window...")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            attachedContentView
            
            // Chat messages scroll area
            chatMessagesScrollView
            
            // Bottom section with controls
            inputAreaView
        }
    }
    // --- END REFACTORED ---
    
    // --- ADDED: Extracted conditional content view ---
    @ViewBuilder
    private var mainContentView: some View {
        if appState.isSelectingAppForCapture {
            AppSelectionView(appState: appState) { selectedApp in
                // Action when app is selected: Call capture function
                appState.captureSelectedAppWindow(appInfo: selectedApp)
                // isSelectingAppForCapture is reset within captureSelectedAppWindow
            }
        } else {
            // Use the extracted view
            chatAndInputView
        }
    }
    // --- END ADDED ---
    
    var body: some View {
        VStack(spacing: 0) {
            mainContentView

            .alert("Screen Recording Permission", isPresented: $showPermissionAlert) {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This app needs Screen Recording permission to capture application windows. Please grant permission in System Settings -> Privacy & Security -> Screen Recording.")
            }
            .alert("Capture Failed", isPresented: $showCaptureErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Could not capture the window for '\(appState.captureErrorAppName)'. Please ensure the window is visible and not minimized.")
            }
            .onChange(of: appState.showPermissionAlert) { newValue in
                showPermissionAlert = newValue
                if newValue {
                    appState.showPermissionAlert = false
                }
            }
            .onChange(of: appState.showCaptureErrorAlert) { newValue in
                showCaptureErrorAlert = newValue
                if newValue {
                    appState.showCaptureErrorAlert = false
                }
            }
            
            .background(
                Group {
                    if themeStyle == "glass" {
                        LiquidGlassBackground(
                            variant: GlassVariant(rawValue: glassVariantRaw) ?? .regular,
                            cornerRadius: 0
                        ) {
                            Color.clear
                        }
                        .ignoresSafeArea()
                    } else if themeStyle == "gradient" {
                        GradientThemeBackground().ignoresSafeArea()
                    } else {
                        ZStack {
                            Color(.windowBackgroundColor)
                                .opacity(0.95)
                                .ignoresSafeArea()
                            
                            LinearGradient(
                                colors: [
                                    Color.purple.opacity(0.02),
                                    Color.blue.opacity(0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .ignoresSafeArea()
                        }
                    }
                }
            )
            .cornerRadius(12)
            .frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity, minHeight: 400, idealHeight: 500, maxHeight: .infinity)
            .preferredColorScheme(.dark)
            .onAppear {
                setupApplicationTracking()
            }
            .onDisappear {
                conversation.cancel()
            }
            .sheet(isPresented: $showQuickActions) {
                QuickActionsView(
                    appState: appState,
                    onComplete: { showQuickActions = false },
                    onPromptSelected: { prompt in
                        userInput = prompt
                    },
                    promptSelectionOnly: true
                )
            }
            .sheet(isPresented: $showAttachmentPreview) {
                if let previewImageData = appState.capturedScreenshotData ?? appState.selectedImages.first,
                   let previewImage = NSImage(data: previewImageData) {
                    AttachmentImagePreview(
                        image: previewImage,
                        title: attachmentPreviewTitle,
                        onClose: { showAttachmentPreview = false }
                    )
                }
            }
        }
        .onDrop(of: dropTypes, isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isDropTargeted ? 0.25 : 0), lineWidth: 2)
        )
        .overlay(alignment: .top) {
            if let feedback = dropFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .cornerRadius(10)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: appState.lastClipboardType) { newValue in
            setAttachmentMessage(for: newValue)
        }
        .onChange(of: appState.selectedText) { _ in
            setAttachmentMessage(for: appState.lastClipboardType)
        }
        .offset(y: dragOffset)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragOffset)
        .highPriorityGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let translation = value.translation.height
                    dragOffset = translation > 0 ? translation : 0
                }
                .onEnded { value in
                    let translation = value.translation.height
                    if translation > 140 {
                        dismissPopup()
                    } else {
                        dragOffset = 0
                    }
                }
        )
    }
    
    private func handleDrop(providers: [NSItemProvider], location: CGPoint) -> Bool {
        var handled = false
        let state = appState
        let textTypeIdentifiers = [
            UTType.plainText.identifier,
            UTType.utf8PlainText.identifier,
            UTType.utf16PlainText.identifier,
            UTType.text.identifier
        ]
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let suggestedName = provider.suggestedName
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = resolveURL(from: item) else {
                        attemptFileRepresentationLoad(provider: provider, suggestedName: suggestedName)
                        return
                    }
                    if url.isFileURL {
                        Task { @MainActor in state.handleDroppedFile(url: url, displayName: suggestedName) }
                        showDropFeedback("Loaded \(suggestedName ?? url.lastPathComponent)")
                    } else {
                        Task { @MainActor in state.handleDroppedURL(url) }
                        showDropFeedback("Loaded \(url.absoluteString)")
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: URL.self) {
                let suggestedName = provider.suggestedName
                provider.loadObject(ofClass: URL.self) { object, _ in
                    guard let url = object else {
                        attemptFileRepresentationLoad(provider: provider, suggestedName: suggestedName)
                        return
                    }
                    if url.isFileURL {
                        Task { @MainActor in state.handleDroppedFile(url: url, displayName: suggestedName) }
                        showDropFeedback("Loaded \(suggestedName ?? url.lastPathComponent)")
                    } else {
                        Task { @MainActor in state.handleDroppedURL(url) }
                        showDropFeedback("Loaded \(url.absoluteString)")
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                let suggestedName = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                    guard let data else {
                        attemptFileRepresentationLoad(provider: provider, suggestedName: suggestedName, fallbackTypeIdentifier: UTType.pdf.identifier)
                        return
                    }
                    Task { @MainActor in state.handleDroppedPDFData(data, fileName: suggestedName) }
                    showDropFeedback("Loaded \(suggestedName ?? "PDF")")
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let suggestedName = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else {
                        attemptFileRepresentationLoad(provider: provider, suggestedName: suggestedName, fallbackTypeIdentifier: UTType.image.identifier)
                        return
                    }
                    Task { @MainActor in state.handleDroppedImageData(data, fileName: suggestedName) }
                    showDropFeedback("Loaded \(suggestedName ?? "Image")")
                }
                handled = true
            } else if let identifier = emailTypeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                attemptFileRepresentationLoad(provider: provider, suggestedName: provider.suggestedName, fallbackTypeIdentifier: identifier)
                handled = true
            } else if let identifier = textTypeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    guard let text = resolveText(from: item) else {
                        attemptFileRepresentationLoad(provider: provider, suggestedName: provider.suggestedName, fallbackTypeIdentifier: identifier)
                        return
                    }
                    Task { @MainActor in state.handleDroppedText(text, sourceName: provider.suggestedName) }
                    showDropFeedback("Loaded \(provider.suggestedName ?? "Text")")
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                attemptFileRepresentationLoad(provider: provider, suggestedName: provider.suggestedName)
                handled = true
            }
            
            if handled {
                break
            }
        }
        
        return handled
    }

    private func attemptFileRepresentationLoad(provider: NSItemProvider, suggestedName: String?, fallbackTypeIdentifier: String = UTType.data.identifier) {
        print("DEBUG (attemptFileRepresentationLoad): Trying fallback with type=\(fallbackTypeIdentifier), suggestedName=\(suggestedName ?? "nil")")
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: fallbackTypeIdentifier) { url, inPlace, error in
            if let url {
                let displayName = suggestedName ?? url.lastPathComponent
                if url.isFileURL {
                    Task { @MainActor in appState.handleDroppedFile(url: url, displayName: displayName) }
                } else {
                    Task { @MainActor in appState.handleDroppedURL(url) }
                }
                showDropFeedback("Loaded \(displayName)")
                return
            }
            
            provider.loadFileRepresentation(forTypeIdentifier: fallbackTypeIdentifier) { tempURL, error in
                guard let tempURL else { return }
                let displayName = suggestedName ?? tempURL.lastPathComponent
                
                let tempDir = FileManager.default.temporaryDirectory
                let destinationURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(displayName)")
                
                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: tempURL, to: destinationURL)
                    Task { @MainActor in
                        appState.handleDroppedFile(url: destinationURL, displayName: displayName, deleteAfterImport: true)
                    }
                    showDropFeedback("Loaded \(displayName)")
                } catch {
                    print("Failed to copy dropped temp file: \(error)")
                }
            }
        }
    }
    
    private func showDropFeedback(_ message: String) {
        DispatchQueue.main.async {
            let id = UUID()
            lastDropFeedbackID = id
            withAnimation {
                dropFeedback = message
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if lastDropFeedbackID == id {
                    withAnimation {
                        dropFeedback = nil
                    }
                }
            }
        }
    }

    private func setAttachmentMessage(for type: ClipboardContentType) {
        if let existingID = attachmentMessageID {
            conversation.messages.removeAll { $0.id == existingID }
            attachmentMessageID = nil
        }
        
        let message: String
        var shouldDisplay = false
        switch type {
        case .pdf:
            message = "User attached a PDF."
            shouldDisplay = !appState.selectedText.isEmpty
        case .url:
            message = "User attached a URL."
            shouldDisplay = !appState.selectedText.isEmpty
        case .image:
            message = "User attached an Image."
            shouldDisplay = !appState.selectedImages.isEmpty
        case .video:
            message = "User attached a Video."
            shouldDisplay = !appState.selectedVideos.isEmpty
        case .text:
            let preview = appState.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            message = preview.count > 240
                ? "Using selected text:\n\n\(String(preview.prefix(240)))..."
                : "Using selected text:\n\n\(preview)"
            shouldDisplay = !preview.isEmpty
        case .none:
            return
        }
        
        guard shouldDisplay else { return }
        
        let newID = UUID()
        conversation.messages.insert(ChatMessage(id: newID, message: message), at: 0)
        attachmentMessageID = newID
    }
    
    private func resolveURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let nsurl = item as? NSURL {
            return nsurl as URL
        }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) {
                print("DEBUG (resolveURL): Resolved via dataRepresentation -> \(url)")
                return url
            }
            var stale = false
            if let bookmarkURL = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                print("DEBUG (resolveURL): Resolved via bookmark -> \(bookmarkURL), stale=\(stale)")
                return bookmarkURL
            }
            if let string = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                if let url = URL(string: string), url.scheme != nil {
                    print("DEBUG (resolveURL): Resolved via UTF8 string -> \(url)")
                    return url
                }
                print("DEBUG (resolveURL): Treating string as file path -> \(string)")
                return URL(fileURLWithPath: string)
            }
        }
        if let string = item as? String {
            if let url = URL(string: string), url.scheme != nil {
                print("DEBUG (resolveURL): Resolved via NSString -> \(url)")
                return url
            }
            print("DEBUG (resolveURL): Treating NSString as file path -> \(string)")
            return URL(fileURLWithPath: string)
        }
        return nil
    }
    
    private func resolveText(from item: NSSecureCoding?) -> String? {
        if let string = item as? String {
            return string
        }
        if let data = item as? Data {
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            if let text = String(data: data, encoding: .utf16) {
                return text
            }
            return String(decoding: data, as: UTF8.self)
        }
        if let attributed = item as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private func dismissPopup() {
        dragOffset = 0
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.closePopupWindow()
        } else {
            NSApp.keyWindow?.close()
        }
    }
    
    private func setupApplicationTracking() {
        // Store initial target application
        if let currentApp = NSWorkspace.shared.frontmostApplication,
           currentApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = currentApp
            appState.previousApplication = currentApp
            print("Initial target application: \(currentApp.localizedName ?? "Unknown")")
        }
        
        // Set up notification observer for application switches
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                targetApplication = app
                appState.previousApplication = app
                print("Updated target application: \(app.localizedName ?? "Unknown")")
            }
        }
        
        populateInitialChatState()
    }
    
    // MARK: - Helper Methods
    
    /// Called when user presses Return or taps Send.
    private func onSend() {
        showAttachmentPreview = false
        switch appState.selectedMode {
        case .chat:
            sendChatMessage()
        case .rewrite:
            rewriteInPlace()
        }
    }
    
    /// Display a short label based on the detected clipboard type.
    private func populateInitialChatState() {
        setAttachmentMessage(for: appState.lastClipboardType)
    }
    
    /// Regular chat: captures provider and attachment state at send time.
    private func sendChatMessage() {
        let prompt = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isProcessing else { return }

        let provider = appState.activeProvider
        let attachment = appState.conversationContext
        let attachmentRevision = appState.attachmentRevision
        let targetApp = targetApplication ?? appState.previousApplication
        let isImageEditRequest = detectImageEditRequest(prompt)
        let imageEditSource = isImageEditRequest ? lastGeneratedImage : nil
        userInput = ""

        conversation.send(prompt, provider: provider, prepareRequest: {
            var context = attachment
            var effectivePrompt = prompt
            var systemPrompt: String?

            if !context.isDocument,
               context.images.isEmpty,
               let targetApp,
               targetApp.bundleIdentifier != Bundle.main.bundleIdentifier,
               !targetApp.isTerminated {
                targetApp.activate(options: .activateIgnoringOtherApps)
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                if let refreshed = await AccessibilityHelper.copyTextFromFocusedElement(targetApplication: targetApp),
                   !refreshed.isEmpty {
                    context.text = refreshed
                    if self.appState.attachmentRevision == attachmentRevision {
                        self.appState.setExternalSelection(refreshed, from: targetApp)
                    }
                }
                NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            }

            if let imageEditSource {
                context.images.append(imageEditSource)
                systemPrompt = """
                Analyze the attached reference image and return the requested result.
                If this provider cannot create images, explain that limitation directly without fabricating an image.
                """
                effectivePrompt = "Using the attached reference image, " + prompt
            }

            return context.request(for: effectivePrompt, systemPrompt: systemPrompt)
        }, onResponse: { response in
            guard !response.images.isEmpty else { return }
            self.lastGeneratedImage = response.images.last
            self.showImageResponse(response)
        })
    }

    private func showImageResponse(_ response: AIResponse) {
        let responseView = ResponseView(
            content: response.displayText,
            selectedText: appState.selectedText,
            option: .general,
            images: response.images,
            providerName: response.providerName
        )
        let window = ResponseWindow(
            with: responseView,
            title: "AI Response with Images",
            hasImages: true
        )
        WindowManager.shared.addResponseWindow(window)
    }

    private func isSpreadsheetApplication(_ application: NSRunningApplication) -> Bool {
        let identifier = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.localizedName?.lowercased() ?? ""
        return identifier.contains("excel") || identifier.contains("numbers") || identifier.contains("sheets")
            || name.contains("excel") || name.contains("numbers") || name.contains("sheets")
    }
    private func detectImageEditRequest(_ prompt: String) -> Bool {
        let lowerPrompt = prompt.lowercased()
        
        // Look for phrases indicating image editing
        let editingPhrases = [
            "edit this image", "modify the image", "change the image",
            "update the image", "adjust the image", "can you change the",
            "make the image", "alter the image", "transform the image",
            "update this", "edit the picture", "change the color", 
            "add to the image", "remove from the image",
            "modify this", "edit it", "change it", "update it",
            "make it more", "make it less", "make it look", "turn it into",
            "convert the image", "apply a filter", "add effect", "add a filter",
            "enhance the image", "crop the image", "resize the image",
            "rotate the image", "flip the image", "add text to the image",
            "apply sepia", "make it black and white", "add border", "add frame",
            "add a background", "remove the background", "change the background",
            "brighten", "darken", "increase contrast", "decrease contrast",
            "add saturation", "remove saturation", "make it warmer", "make it cooler",
            "add shadows", "remove shadows", "can you make", "please edit",
            "create a version", "create a new version", "new version", 
            "similar to this", "based on this", "like this one", 
            "use this image", "using this image", "from this image"
        ]
        
        return editingPhrases.contains { lowerPrompt.contains($0) } && lastGeneratedImage != nil
    }
    
    /// Clears the chat and rechecks the clipboard.
    private func startNewChat() {
        conversation.reset()
        attachmentMessageID = nil
        showAttachmentPreview = false
        userInput = ""
        lastGeneratedImage = nil
        appState.clearConversationContext()
        appState.recheckClipboard()
    }

    private var attachmentPreviewTitle: String {
        let name = appState.attachedContentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name ?? "Attachment" : "Attachment"
    }
    
    /// Rewrites the original selection only while the captured Accessibility target is unchanged.
    private func rewriteInPlace() {
        let instructions = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty, !isProcessing else { return }

        let currentApp = NSWorkspace.shared.frontmostApplication
        guard let targetApp = currentApp?.bundleIdentifier != Bundle.main.bundleIdentifier
                ? currentApp : targetApplication,
              !targetApp.isTerminated,
              targetApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            conversation.messages.append(ChatMessage(role: "error", content: "Select text in another app first."))
            return
        }

        let provider = appState.activeProvider
        let isSpreadsheet = isSpreadsheetApplication(targetApp)
        userInput = ""
        targetApplication = targetApp
        appState.previousApplication = targetApp

        conversation.perform { id in
            targetApp.activate(options: .activateIgnoringOtherApps)
            try? await Task.sleep(for: .milliseconds(300))
            guard self.conversation.isCurrent(id),
                  let externalText = await AccessibilityHelper.copyTextFromFocusedElement(targetApplication: targetApp),
                  !externalText.isEmpty else {
                guard self.conversation.isCurrent(id) else { return }
                self.conversation.messages.append(ChatMessage(role: "error", content: "No selected text was found in the target app."))
                return
            }

            let replacementTarget: TextReplacementTarget
            do {
                replacementTarget = try AccessibilityHelper.captureReplacementTarget(
                    expectedText: externalText,
                    targetApplication: targetApp
                )
            } catch {
                self.conversation.messages.append(ChatMessage(role: "error", content: error.localizedDescription))
                NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
                return
            }

            self.appState.setExternalSelection(externalText, from: targetApp)
            let formatInstruction = isSpreadsheet
                ? "Preserve the table structure exactly, including tabs, commas, line breaks, and cell positions."
                : ""
            let prompt = """
            Follow the user's instructions. Return only the replacement text, with no disclaimer or explanation.

            \(formatInstruction)
            Instructions: \(instructions)

            Original text:
            \(externalText)
            """

            do {
                let response = try await provider.processText(
                    systemPrompt: nil,
                    userPrompt: prompt,
                    images: [],
                    videos: []
                )
                guard self.conversation.isCurrent(id) else { return }

                if !response.images.isEmpty {
                    self.lastGeneratedImage = response.images.last
                    self.showImageResponse(response)
                } else if response.isTruncated {
                    self.conversation.messages.append(ChatMessage(
                        role: "assistant",
                        content: response.text,
                        providerName: response.providerName,
                        isTruncated: true
                    ))
                    self.conversation.messages.append(ChatMessage(
                        role: "error",
                        content: "The incomplete result was not pasted."
                    ))
                } else {
                    do {
                        try await AccessibilityHelper.replaceTextInCapturedTarget(
                            with: response.text,
                            target: replacementTarget
                        )
                    } catch {
                        self.conversation.messages.append(ChatMessage(
                            role: "assistant",
                            content: response.text,
                            providerName: response.providerName
                        ))
                        self.conversation.messages.append(ChatMessage(role: "error", content: error.localizedDescription))
                    }
                }
            } catch {
                guard self.conversation.isCurrent(id) else { return }
                self.conversation.messages.append(ChatMessage(role: "error", content: error.localizedDescription))
            }
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }
    }
    
    /// Copies the chat conversation to the clipboard
    private func copyChatToClipboard() {
        // Format the conversation
        let conversationText = conversation.messages.map { item in
            item.message // Each message already includes the role prefix
        }.joined(separator: "\n\n")
        
        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conversationText, forType: .string)
        
        // Add a message to inform the user
        conversation.messages.append(ChatMessage(message: "System: Chat conversation copied to clipboard."))
    }
    
    private func saveImage(_ imageData: Data) {
        guard let image = NSImage(data: imageData) else {
            print("Failed to create image from data")
            return
        }
        
        // Create save panel
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg]
        
        // Create date formatter for default filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dateString = dateFormatter.string(from: Date())
        
        savePanel.nameFieldStringValue = "generated-image-\(dateString).png"
        savePanel.message = "Save Generated Image"
        savePanel.prompt = "Save"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    // Determine file type based on the extension
                    let isJPEG = url.pathExtension.lowercased() == "jpg" || 
                                 url.pathExtension.lowercased() == "jpeg"
                    
                    // Convert NSImage to the appropriate format
                    let imageRep = NSBitmapImageRep(data: imageData)
                    let fileData: Data?
                    
                    if isJPEG {
                        fileData = imageRep?.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                    } else {
                        fileData = imageRep?.representation(using: .png, properties: [:])
                    }
                    
                    if let fileData = fileData {
                        try fileData.write(to: url)
                        print("Image successfully saved to \(url.path)")
                    } else {
                        print("Failed to create image representation")
                    }
                } catch {
                    print("Error saving image: \(error.localizedDescription)")
                }
            }
        }
    }
}

// --- ADDED: New View for App Selection ---
struct AppSelectionView: View {
    @ObservedObject var appState: AppState
    var onAppSelected: (AppInfo) -> Void

    @State private var searchText: String = ""

    var filteredApps: [AppInfo] {
        if searchText.isEmpty {
            return appState.runningApplications
        } else {
            return appState.runningApplications.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select Application Window to Capture")
                .font(.headline)
                .fontWeight(.bold)
                .padding(.horizontal)
                .padding(.top)

            TextField("Search Applications", text: $searchText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal)

            List {
                ForEach(filteredApps) { appInfo in
                    Button(action: {
                        onAppSelected(appInfo)
                    }) {
                        HStack {
                            Image(nsImage: appInfo.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                            Text(appInfo.name)
                            Spacer()
                        }
                        .contentShape(Rectangle()) // Make entire HStack tappable
                    }
                    .glassButtonStyle(variant: .regular) // Use plain style for list items
                }
            }
            .listStyle(InsetListStyle()) // Modern list style
            .frame(maxHeight: .infinity) // Allow list to expand

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.isSelectingAppForCapture = false // Close selection view
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor).opacity(0.9)) // Match popup background
        .transition(.opacity) // Add a subtle transition
    }
}
// --- END ADDED ---

// --- ADDED: Preview Provider for AppSelectionView ---
struct AppSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        // Create mock AppState for preview
        let mockAppState = AppState.shared
        mockAppState.runningApplications = [
            AppInfo(id: 1, name: "Finder", icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!),
            AppInfo(id: 2, name: "Safari", icon: NSImage(systemSymbolName: "safari", accessibilityDescription: nil)!),
            AppInfo(id: 3, name: "Notes", icon: NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)!),
            AppInfo(id: 4, name: "Long Application Name Example", icon: NSImage(systemSymbolName: "app", accessibilityDescription: nil)!),
        ]
        mockAppState.isSelectingAppForCapture = true

        return AppSelectionView(appState: mockAppState) { appInfo in
            print("Preview selected: \(appInfo.name)")
        }
        .frame(width: 350, height: 400)
    }
}
// --- END ADDED ---

private enum AssistantMarkdownBlock {
    case text(String)
    case heading(level: Int, text: String)
    case list(AssistantMarkdownList)
    case table(AssistantMarkdownTable)
    case image(AssistantMarkdownImage)
}

private struct AssistantMarkdownList {
    let items: [AssistantMarkdownListItem]
}

private struct AssistantMarkdownListItem {
    let marker: String
    let text: String
}

private struct AssistantMarkdownTable {
    let headers: [String]
    let rows: [[String]]
}

private struct AssistantMarkdownImage {
    let altText: String
    let source: String
}

private enum AssistantMarkdownParser {
    static func parse(_ text: String) -> [AssistantMarkdownBlock] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [AssistantMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                continue
            }

            if let heading = parseHeading(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let image = parseImage(line) {
                blocks.append(.image(image))
                index += 1
                continue
            }

            if let list = parseList(lines, startingAt: index) {
                blocks.append(.list(list.value))
                index = list.nextIndex
                continue
            }

            if let table = parseTable(lines, startingAt: index) {
                blocks.append(.table(table.value))
                index = table.nextIndex
                continue
            }

            var textLines: [String] = []
            while index < lines.count {
                let current = lines[index]
                if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                if isKnownBlockStart(lines, at: index) {
                    break
                }
                textLines.append(current)
                index += 1
            }

            let value = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                blocks.append(.text(value))
            } else {
                index += 1
            }
        }

        return blocks
    }

    private static func isKnownBlockStart(_ lines: [String], at index: Int) -> Bool {
        guard index < lines.count else { return false }
        return parseHeading(lines[index]) != nil
            || parseImage(lines[index]) != nil
            || parseListItem(lines[index]) != nil
            || parseTable(lines, startingAt: index) != nil
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        var currentIndex = trimmed.startIndex

        while currentIndex < trimmed.endIndex,
              trimmed[currentIndex] == "#",
              level < 6 {
            level += 1
            currentIndex = trimmed.index(after: currentIndex)
        }

        guard level > 0,
              currentIndex < trimmed.endIndex,
              trimmed[currentIndex].isWhitespace else {
            return nil
        }

        let textStart = trimmed.index(after: currentIndex)
        let headingText = String(trimmed[textStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return headingText.isEmpty ? nil : (level, headingText)
    }

    private static func parseImage(_ line: String) -> AssistantMarkdownImage? {
        guard let match = firstMatch(in: line.trimmingCharacters(in: .whitespacesAndNewlines), pattern: #"^!\[([^\]]*)\]\(([^)]+)\)$"#),
              match.count == 3 else {
            return nil
        }

        return AssistantMarkdownImage(altText: match[1], source: match[2])
    }

    private static func parseList(_ lines: [String], startingAt index: Int) -> (value: AssistantMarkdownList, nextIndex: Int)? {
        var items: [AssistantMarkdownListItem] = []
        var currentIndex = index

        while currentIndex < lines.count {
            guard let item = parseListItem(lines[currentIndex]) else {
                break
            }
            items.append(item)
            currentIndex += 1
        }

        return items.isEmpty ? nil : (AssistantMarkdownList(items: items), currentIndex)
    }

    private static func parseListItem(_ line: String) -> AssistantMarkdownListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let unordered = firstMatch(in: trimmed, pattern: #"^([*+-])\s+(.+)$"#),
           unordered.count == 3 {
            return AssistantMarkdownListItem(marker: "•", text: unordered[2])
        }

        if let ordered = firstMatch(in: trimmed, pattern: #"^(\d+[.)])\s+(.+)$"#),
           ordered.count == 3 {
            return AssistantMarkdownListItem(marker: ordered[1], text: ordered[2])
        }

        return nil
    }

    private static func parseTable(_ lines: [String], startingAt index: Int) -> (value: AssistantMarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headers = pipeCells(in: lines[index]),
              let separator = pipeCells(in: lines[index + 1]),
              headers.count > 1,
              separator.count == headers.count,
              separator.allSatisfy(isTableSeparatorCell) else {
            return nil
        }

        var rows: [[String]] = []
        var currentIndex = index + 2

        while currentIndex < lines.count {
            guard let cells = pipeCells(in: lines[currentIndex]),
                  !cells.allSatisfy(isTableSeparatorCell) else {
                break
            }
            rows.append(cells)
            currentIndex += 1
        }

        return (AssistantMarkdownTable(headers: headers, rows: rows), currentIndex)
    }

    private static func pipeCells(in line: String) -> [String]? {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("|") else { return nil }

        if value.hasPrefix("|") {
            value.removeFirst()
        }
        if value.hasSuffix("|") {
            value.removeLast()
        }

        let cells = value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        return cells.count > 1 ? cells : nil
    }

    private static func isTableSeparatorCell(_ value: String) -> Bool {
        firstMatch(in: value, pattern: #"^:?-{3,}:?$"#) != nil
    }

    private static func firstMatch(in value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: nsRange) else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard let swiftRange = Range(range, in: value) else {
                return ""
            }
            return String(value[swiftRange])
        }
    }
}

private struct AttachmentImagePreview: View {
    let image: NSImage
    let title: String
    let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panStartOffset: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 16)

                Button {
                    panOffset = .zero
                    zoom = 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Reset zoom")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close preview")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            GeometryReader { proxy in
                let fittedSize = fittedImageSize(in: proxy.size)
                let scaledImageSize = CGSize(
                    width: fittedSize.width * zoom,
                    height: fittedSize.height * zoom
                )

                ZStack {
                    Color.black.opacity(0.28)

                    Image(nsImage: image)
                        .resizable()
                        .frame(width: scaledImageSize.width, height: scaledImageSize.height)
                        .offset(panOffset)
                }
                .contentShape(Rectangle())
                .clipped()
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if panStartOffset == nil {
                                panStartOffset = panOffset
                            }
                            let start = panStartOffset ?? .zero
                            let proposedOffset = CGSize(
                                width: start.width + value.translation.width,
                                height: start.height + value.translation.height
                            )
                            panOffset = clampedPanOffset(
                                proposedOffset,
                                scaledImageSize: scaledImageSize,
                                viewportSize: proxy.size
                            )
                        }
                        .onEnded { _ in
                            panStartOffset = nil
                        }
                )
                .onChange(of: zoom) { oldZoom, newZoom in
                    guard oldZoom > 0 else { return }
                    let zoomRatio = newZoom / oldZoom
                    let scaledOffset = CGSize(
                        width: panOffset.width * zoomRatio,
                        height: panOffset.height * zoomRatio
                    )
                    panOffset = clampedPanOffset(
                        scaledOffset,
                        scaledImageSize: scaledImageSize,
                        viewportSize: proxy.size
                    )
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    zoom = max(1, zoom - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(zoom <= 1)
                .help("Zoom out")

                Slider(value: $zoom, in: 1...5, step: 0.25)
                    .frame(width: 220)

                Button {
                    zoom = min(5, zoom + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(zoom >= 5)
                .help("Zoom in")

                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.vertical, 10)
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
    }

    private func fittedImageSize(in availableSize: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            return availableSize
        }

        let scale = min(
            availableSize.width / image.size.width,
            availableSize.height / image.size.height
        )
        return CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    }

    private func clampedPanOffset(
        _ offset: CGSize,
        scaledImageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        let horizontalLimit = max(0, (scaledImageSize.width - viewportSize.width) / 2)
        let verticalLimit = max(0, (scaledImageSize.height - viewportSize.height) / 2)

        return CGSize(
            width: min(max(offset.width, -horizontalLimit), horizontalLimit),
            height: min(max(offset.height, -verticalLimit), verticalLimit)
        )
    }
}

private struct AssistantMarkdownReplyView: View {
    let text: String
    let onSelectionChange: (String) -> Void

    private var blocks: [AssistantMarkdownBlock] {
        AssistantMarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdownBlock) -> some View {
        switch block {
        case .text(let value):
            SelectableInlineMarkdownText(text: value, onSelectionChange: onSelectionChange)

        case .heading(let level, let value):
            SelectableInlineMarkdownText(
                text: value,
                fontSize: headingFontSize(for: level),
                fontWeight: .semibold,
                onSelectionChange: onSelectionChange
            )

        case .list(let list):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.marker)
                            .font(.system(size: NSFont.systemFontSize, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: markerWidth(for: item.marker), alignment: .trailing)

                        SelectableInlineMarkdownText(text: item.text, onSelectionChange: onSelectionChange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .table(let table):
            tableView(table)

        case .image(let image):
            AssistantMarkdownImageView(image: image)
        }
    }

    private func tableView(_ table: AssistantMarkdownTable) -> some View {
        let widths = tableColumnWidths(table)

        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(table.headers, widths: widths, isHeader: true)

                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, widths: widths, isHeader: false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
            )
        }
    }

    private func tableRow(_ row: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(widths.indices, id: \.self) { index in
                SelectableInlineMarkdownText(
                    text: index < row.count ? row[index] : "",
                    fontWeight: isHeader ? .semibold : .bold,
                    onSelectionChange: onSelectionChange
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: widths[index], alignment: .leading)
                .background(isHeader ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                .overlay(alignment: .trailing) {
                    if index < widths.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 0.5)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.5)
        }
    }

    private func tableColumnWidths(_ table: AssistantMarkdownTable) -> [CGFloat] {
        table.headers.indices.map { index in
            let values = [table.headers[index]] + table.rows.map { row in
                index < row.count ? row[index] : ""
            }
            let characterCount = values.map(\.count).max() ?? 0
            return min(max(CGFloat(characterCount) * 7 + 28, 84), 220)
        }
    }

    private func markerWidth(for marker: String) -> CGFloat {
        marker == "•" ? 16 : 30
    }

    private func headingFontSize(for level: Int) -> CGFloat {
        switch level {
        case 1:
            return NSFont.systemFontSize + 5
        case 2:
            return NSFont.systemFontSize + 2
        default:
            return NSFont.systemFontSize
        }
    }
}

private struct AssistantMarkdownImageView: View {
    let image: AssistantMarkdownImage

    var body: some View {
        Group {
            if let url = remoteURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: 360, minHeight: 120)
                    case .success(let loadedImage):
                        styledImage(loadedImage)
                    case .failure:
                        imageFallback
                    @unknown default:
                        imageFallback
                    }
                }
            } else if let nsImage = localImage {
                styledImage(Image(nsImage: nsImage))
            } else {
                imageFallback
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remoteURL: URL? {
        guard let url = URL(string: image.source),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    private var localImage: NSImage? {
        if let url = URL(string: image.source), url.isFileURL {
            return NSImage(contentsOf: url)
        }

        let expandedPath = NSString(string: image.source).expandingTildeInPath
        return NSImage(contentsOfFile: expandedPath)
    }

    private var imageFallback: some View {
        Text(image.altText.isEmpty ? "Image could not be displayed" : image.altText)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func styledImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
    }
}

private struct SelectableInlineMarkdownText: View {
    let text: String
    var fontSize: CGFloat = NSFont.systemFontSize
    var fontWeight: NSFont.Weight = .bold
    let onSelectionChange: (String) -> Void

    @State private var height: CGFloat = 24

    var body: some View {
        SelectableAssistantReplyText(
            text: text,
            height: $height,
            onSelectionChange: onSelectionChange,
            fontSize: fontSize,
            fontWeight: fontWeight
        )
        .frame(height: height, alignment: .leading)
    }
}

private struct SelectableAssistantReplyText: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat
    let onSelectionChange: (String) -> Void
    var fontSize: CGFloat = NSFont.systemFontSize
    var fontWeight: NSFont.Weight = .bold
    var textColor: NSColor = .labelColor

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = textColor
        textView.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        let renderKey = "\(text)|\(fontSize)|\(fontWeight)"
        if context.coordinator.renderKey != renderKey {
            textView.textStorage?.setAttributedString(inlineAttributedString())
            textView.textColor = textColor
            context.coordinator.renderKey = renderKey
        }

        DispatchQueue.main.async {
            guard let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }

            let fittingWidth = max(textView.bounds.width, 1)
            textContainer.containerSize = CGSize(
                width: fittingWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let measuredHeight = max(24, ceil(usedRect.height + textView.textContainerInset.height * 2))

            if abs(height - measuredHeight) > 0.5 {
                height = measuredHeight
            }
        }
    }

    private func inlineAttributedString() -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)

        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard mutable.length > 0 else {
            return mutable
        }

        mutable.addAttribute(.foregroundColor, value: textColor, range: fullRange)
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let existingFont = value as? NSFont
            let traits = existingFont?.fontDescriptor.symbolicTraits ?? []
            let resolvedWeight: NSFont.Weight = traits.contains(.bold) ? .bold : fontWeight
            var resolvedFont = NSFont.systemFont(ofSize: fontSize, weight: resolvedWeight)

            if traits.contains(.italic) {
                resolvedFont = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .italicFontMask)
            }

            mutable.addAttribute(.font, value: resolvedFont, range: range)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        return mutable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: (String) -> Void
        var renderKey: String?

        init(onSelectionChange: @escaping (String) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  NSMaxRange(range) <= (textView.string as NSString).length else {
                onSelectionChange("")
                return
            }

            let selection = (textView.string as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onSelectionChange(selection)
        }
    }
}

struct PopupView_Previews: PreviewProvider {
    static var previews: some View {
        let appState = AppState.shared
// ... existing code ...
    }
}
