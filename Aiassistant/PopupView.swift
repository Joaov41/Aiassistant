import SwiftUI
import Cocoa  // For CGEvent and related APIs
import MarkdownUI  // Add this import
import UniformTypeIdentifiers

struct PopupView: View {
    @ObservedObject var appState: AppState
    @AppStorage("theme_style") private var themeStyle: String = "standard"
    @AppStorage("glass_variant") private var glassVariantRaw: Int = 11
    
    // Local chat state for the conversation with unique IDs and image support
    @State private var chatMessages: [(id: UUID, message: String, images: [Data])] = []
    @State private var userInput: String = ""
    @State private var pccChatTranscriptName: String? = nil
    @State private var selectedReplyMessageID: UUID?
    @State private var selectedReplyText: String = ""
    @State private var replyTextHeights: [UUID: CGFloat] = [:]
    
    // Track the most recently generated image for editing requests
    @State private var lastGeneratedImage: Data? = nil

    // Show Quick Actions menu for rewrite mode
    @State private var showQuickActions = false
    
    // Track whether we are calling the AI
    @State private var isProcessing = false
    
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
                    variant: GlassVariant(rawValue: glassVariantRaw) ?? .v11, 
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
                ForEach(chatMessages, id: \.id) { item in
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
		                                SelectableAssistantReplyText(
		                                    text: response,
		                                    height: Binding(
		                                        get: { replyTextHeights[item.id, default: 24] },
		                                        set: { replyTextHeights[item.id] = $0 }
		                                    ),
		                                    onSelectionChange: { selection in
		                                        selectedReplyMessageID = selection.isEmpty ? nil : item.id
		                                        selectedReplyText = selection
		                                    }
		                                )
		                                .frame(height: replyTextHeights[item.id, default: 24], alignment: .leading)
		                                
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
		                                    .glassButtonStyle(variant: .v12)
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
                                                .glassButtonStyle(variant: .v10, cornerRadius: 15)
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
                                        .glassButtonStyle(variant: .v12)
                                        
                                        if item.id == chatMessages.last?.id && item.images.contains(where: { $0 == lastGeneratedImage }) {
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
                                            .glassButtonStyle(variant: .v14)
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
                .glassButtonStyle(variant: .v8)
                .opacity(appState.selectedMode == .chat ? 1.0 : 0.6)
                
                Button(action: { appState.selectedMode = .rewrite }) {
                    Label("Rewrite", systemImage: "pencil.line")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(variant: .v8)
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
                    .glassButtonStyle(variant: .v8)
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
                .glassButtonStyle(variant: .v8)
                .disabled(isProcessing || userInput.isEmpty)
            }
            .padding()
            
        // Bottom row: New Chat button with modern styling
        HStack {
            Button(action: startNewChat) {
                Label("New Chat", systemImage: "plus.message")
            }
            .glassButtonStyle(variant: .v8)
            .padding(.leading, 12)
            
            Spacer()
            
            Button(action: {
                appState.updateRunningApplications()
                appState.isSelectingAppForCapture = true
            }) {
                Label("Capture Window", systemImage: "rectangle.on.rectangle")
            }
            .glassButtonStyle(variant: .v8)
            .help("Capture a screenshot from another application window")
            
            Spacer()
            
            Button(action: copyChatToClipboard) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .glassButtonStyle(variant: .v8)
            .padding(.trailing, 12)
        }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var attachedContentView: some View {
        if let attachmentName = appState.attachedContentName, !attachmentName.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(attachmentName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
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
            // --- ADDED: Display Captured Image if present ---
            if let previewImageData = appState.capturedScreenshotData ?? appState.selectedImages.first {
                VStack {
                    Text("Captured Window:")
                        .font(.headline)
                        .fontWeight(.bold)
                        .padding(.top)
                    // Display the first captured image (assuming window capture provides one)
                    if let nsImage = NSImage(data: previewImageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200) // Limit height in the preview
                            .padding()
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(8)
                    }
                    Divider()
                }
                .padding(.horizontal)
            } else if appState.isProcessing {
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
            // --- END ADDED ---

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
                            variant: GlassVariant(rawValue: glassVariantRaw) ?? .v11,
                            cornerRadius: 0
                        ) {
                            Color.clear
                        }
                        .ignoresSafeArea()
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
        .onChange(of: appState.retainedTextContext) { _ in
            pccChatTranscriptName = nil
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
                        state.handleDroppedFile(url: url, displayName: suggestedName)
                        showDropFeedback("Loaded \(suggestedName ?? url.lastPathComponent)")
                    } else {
                        state.handleDroppedURL(url)
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
                        state.handleDroppedFile(url: url, displayName: suggestedName)
                        showDropFeedback("Loaded \(suggestedName ?? url.lastPathComponent)")
                    } else {
                        state.handleDroppedURL(url)
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
                    state.handleDroppedPDFData(data, fileName: suggestedName)
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
                    state.handleDroppedImageData(data, fileName: suggestedName)
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
                    state.handleDroppedText(text, sourceName: provider.suggestedName)
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
                    appState.handleDroppedFile(url: url, displayName: displayName)
                } else {
                    appState.handleDroppedURL(url)
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
                    appState.handleDroppedFile(url: destinationURL, displayName: displayName)
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
            chatMessages.removeAll { $0.id == existingID }
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
            // Avoid showing a banner for plain text to keep the UI clean on launch.
            return
        case .none:
            return
        }
        
        guard shouldDisplay else { return }
        
        let newID = UUID()
        chatMessages.insert((id: newID, message: message, images: []), at: 0)
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
    
    /// Regular chat: combines any extracted text with the user's typed message.
    private func sendChatMessage() {
        guard !userInput.isEmpty else { return }
        
        // --- Make function async --- 
        Task { 
            // --- Move existing logic inside Task --- 
            let typedPrompt = userInput
            userInput = ""
            chatMessages.append((id: UUID(), message: "User: \(typedPrompt)", images: []))
            
            let retainedContext = appState.retainedTextContext.trimmingCharacters(in: .whitespacesAndNewlines)
            var textContext = retainedContext.isEmpty ? appState.selectedText : appState.retainedTextContext
            let hasRetainedDocumentContext = !retainedContext.isEmpty
            
            if !hasRetainedDocumentContext,
               let targetApp = targetApplication ?? appState.previousApplication,
               targetApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                let ourApp = NSRunningApplication.current
                print("DEBUG: Attempting to refresh chat context from \(targetApp.localizedName ?? "Unknown").")
                
                targetApp.activate(options: .activateIgnoringOtherApps)
                try? await Task.sleep(nanoseconds: 350_000_000)
                
                if let refreshedText = AccessibilityHelper.copyTextFromFocusedElement(targetApplication: targetApp),
                   !refreshedText.isEmpty {
                    await MainActor.run {
                        appState.selectedText = refreshedText
                        appState.lastClipboardType = .text
                        appState.previousApplication = targetApp
                        self.targetApplication = targetApp
                    }
                    textContext = refreshedText
                    print("DEBUG: Successfully refreshed chat context from target application.")
                } else {
                    await MainActor.run {
                        appState.previousApplication = targetApp
                        self.targetApplication = targetApp
                    }
                    print("DEBUG: Failed to refresh chat context from target application; falling back to cached selection.")
                }
                
                await MainActor.run {
                    ourApp.activate(options: .activateIgnoringOtherApps)
                }
            } else if textContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("DEBUG: No target application available and cached chat context is empty.")
            }
            
            // --- REVISED IMAGE HANDLING --- 
            // Determine images to send based on context
            var imagesToIncludeForProcessing: [Data] = []
            var clearSelectedImagesAfterSend = false

            if let conversationImage = appState.capturedImageForConversation {
                // 1. Prioritize conversation context image (from window capture)
                imagesToIncludeForProcessing = [conversationImage]
                print("Using conversation image context (window capture).")
                // Don't clear selectedImages if we are using conversation context
                clearSelectedImagesAfterSend = false 
            } else if !appState.selectedImages.isEmpty {
                // 2. Use clipboard/selection image if no conversation image exists
                imagesToIncludeForProcessing = appState.selectedImages
                // Mark for clearing *after* this send, as it's temporary context
                clearSelectedImagesAfterSend = true 
                print("Using temporary clipboard/selection image context.")
                // --- ADDED: Promote clipboard image to conversation context --- 
                if let clipboardImage = appState.selectedImages.first {
                    print("Promoting clipboard image to conversation context.")
                    appState.capturedImageForConversation = clipboardImage
                }
                // --- END ADDED ---
            } else {
                // 3. No image context
                print("No image context for this message.")
                clearSelectedImagesAfterSend = false
            }
            
            // Detect if this is an image editing request using the *last generated* image
            let isImageEditRequest = detectImageEditRequest(typedPrompt)
            // If this is an edit request, ensure the last generated image is included.
            if isImageEditRequest, let lastImage = lastGeneratedImage, !imagesToIncludeForProcessing.contains(lastImage) {
                print("Image edit request detected - including last generated image")
                imagesToIncludeForProcessing.append(lastImage) 
            }
            // --- END REVISED IMAGE HANDLING ---
            
            // Text context already contains the freshest captured selection (if available)
            isProcessing = true
            
            let trimmedTextContext = textContext.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Create system prompt for image editing
            let systemPrompt: String?
            let finalPrompt: String
            
            if isImageEditRequest && lastGeneratedImage != nil {
                systemPrompt = """
                You are an AI that can generate new images based on reference images. The user has attached an image and wants you to create a new version with specific changes.
                When you receive an image along with a request for modifications:
                1. Examine the attached image carefully
                2. Create a NEW image that incorporates the requested changes 
                3. Return the newly generated image
                
                Your strength is in generating images based on examples and descriptions.
                """
                
                finalPrompt = """
                I've attached an image and I'd like you to create a new version with these changes: \(typedPrompt)
                
                Please use the attached image as a reference and create a new image that incorporates these modifications.
                The new image should maintain the overall essence of the original but with the requested changes applied.
                """
            } else {
                if trimmedTextContext.isEmpty {
                    systemPrompt = nil
                    finalPrompt = typedPrompt
                } else if hasRetainedDocumentContext {
                    systemPrompt = """
                    You are a precise document extraction assistant. Use only the provided Context.
                    If an amount, currency, date, or field is not explicitly present in the Context, say it is not found.
                    Do not infer subtotals, taxes, totals, conversions, or missing values unless the user explicitly asks you to calculate from listed amounts.
                    When answering extraction questions, quote the exact label and amount from the Context.
                    """
                    finalPrompt = """
                    Context:
                    ---
                    \(trimmedTextContext)
                    ---

                    User says: \(typedPrompt)
                    """
                } else {
                    systemPrompt = nil
                    finalPrompt = """
                    Use this context if it is relevant to the user's message. If it is not relevant, answer normally.

                    Context:
                    ---
                    \(trimmedTextContext)
                    ---

                    User says: \(typedPrompt)
                    """
                }
            }
            
            // isProcessing = true // Moved up for URL fetch
            // Task { // Removed outer Task, already inside one
                do {
                    let aiResponse: AIResponse
                    if AppSettings.shared.selectedAIProvider == .applePCC {
                        aiResponse = try await appState.pccProvider.processText(
                            systemPrompt: systemPrompt,
                            userPrompt: finalPrompt,
                            images: imagesToIncludeForProcessing,
                            videos: appState.selectedVideos,
                            transcriptName: hasRetainedDocumentContext ? nil : pccChatTranscriptName
                        )
                        if !hasRetainedDocumentContext, let transcriptName = aiResponse.pccTranscriptName {
                            pccChatTranscriptName = transcriptName
                        }
                    } else {
                        aiResponse = try await appState.activeProvider.processText(
                            systemPrompt: systemPrompt,
                            userPrompt: finalPrompt,
                            images: imagesToIncludeForProcessing,
                            videos: appState.selectedVideos
                        )
                    }
                    
                    if !aiResponse.images.isEmpty {
                        // Store the most recent generated image for potential future edits
                        if let latestImage = aiResponse.images.last {
                            lastGeneratedImage = latestImage
                        }
                        
                        // If there are images in the response, create a response window
                        DispatchQueue.main.async {
                            // Add debug print
                            print("Creating response window with \(aiResponse.images.count) images")
                            
                            // Create the response view first
                            let responseView = ResponseView(
                                content: aiResponse.text,
                                selectedText: appState.selectedText,
                                option: WritingOption.general,
                                images: aiResponse.images,
                                providerName: aiResponse.providerName,
                                pccTranscriptName: aiResponse.pccTranscriptName
                            )
                            
                            // Create the window using the view
                            let window = ResponseWindow(
                                with: responseView,
                                title: "AI Response with Images",
                                hasImages: !aiResponse.images.isEmpty
                            )
                            
                            WindowManager.shared.addResponseWindow(window)
                            
                            // Add a message to the chat including the image data
                            self.chatMessages.append((
                                id: UUID(), 
                                message: "Assistant: \(aiResponse.text)",
                                images: aiResponse.images
                            ))
                        }
                    } else if isImageEditRequest && lastGeneratedImage != nil {
                        // Handle the case where an image edit was requested but no image was returned
                        DispatchQueue.main.async {
                            print("Image edit request acknowledged but no modified image was returned")
                            
                            // Provide feedback to user about the limitation
                            let limitationMessage = """
                            I attempted to create a modified version of the image based on your request, but wasn't able to generate a new image.
                            
                            Please try asking for the modification in a different way, such as:
                            
                            "Create a version of this image with a blue background"
                            "Transform this image to have a more cartoon-like style"
                            "Make a similar image but with mountains in the background"
                            
                            This often works better with more specific, descriptive instructions.
                            """
                            
                            chatMessages.append((id: UUID(), message: "Assistant: \(limitationMessage)", images: []))
                        }
                    } else {
                        // Regular text response
                        chatMessages.append((id: UUID(), message: "Assistant: \(aiResponse.text)", images: []))
                    }
                } catch {
                    chatMessages.append((id: UUID(), message: "Error: \(error.localizedDescription)", images: []))
                }
                isProcessing = false

                // --- ADDED: Clear temporary images only if they were used --- 
                if clearSelectedImagesAfterSend {
                    DispatchQueue.main.async {
                         print("Clearing temporary selectedImages after send.")
                         appState.selectedImages = []
                    }
                }
                // --- END ADDED ---
            //} // Removed outer Task bracket
        } // End of Task wrapper
    }
    
    // Detect if a prompt is requesting edits to a previously generated image
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
        chatMessages.removeAll()
        attachmentMessageID = nil
        userInput = ""
        pccChatTranscriptName = nil
        lastGeneratedImage = nil
        appState.clearConversationContext()
        appState.recheckClipboard()
    }
    
    /// The inline rewrite flow
    private func rewriteInPlace() {
        guard !userInput.isEmpty else {
            print("No rewrite instructions typed.")
            return
        }
        isProcessing = true
        print("DEBUG: rewriteInPlace function started.") // Log start
        
        // Get the current frontmost application if available, otherwise use stored target
        let currentApp = NSWorkspace.shared.frontmostApplication
        let targetApp = currentApp?.bundleIdentifier != Bundle.main.bundleIdentifier ? currentApp : targetApplication
        
        guard let targetApp = targetApp,
              !targetApp.isTerminated else {
            print("DEBUG: rewriteInPlace FAILED - targetApp is nil or terminated.")
            print("DEBUG: targetApp = \(targetApp?.localizedName ?? "nil"), isTerminated = \(targetApp?.isTerminated ?? true)")
            print("Please select text in another application first")
            isProcessing = false
            return
        }
        
        // Make sure it's not our own app
        if targetApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            print("DEBUG: rewriteInPlace FAILED - targetApp is our own app.")
            print("Please select text in another application first")
            isProcessing = false
            return
        }
        
        // Update stored target application references
        self.targetApplication = targetApp
        appState.previousApplication = targetApp
        
        // Check if this is a spreadsheet application
        let isSpreadsheetApp = targetApp.bundleIdentifier?.contains("excel") == true || 
                               targetApp.bundleIdentifier?.contains("numbers") == true || 
                               targetApp.bundleIdentifier?.contains("sheets") == true ||
                               targetApp.localizedName?.lowercased().contains("excel") == true ||
                               targetApp.localizedName?.lowercased().contains("numbers") == true ||
                               targetApp.localizedName?.lowercased().contains("sheets") == true
        
        print("Target app for text operation: \(targetApp.localizedName ?? "Unknown") (\(targetApp.bundleIdentifier ?? "unknown bundle id"))")
        print("Is spreadsheet app: \(isSpreadsheetApp)")
        
        // Store a reference to our app for later reactivation
        let ourApp = NSRunningApplication.current
        
        Task {
            // Step 1: Activate target app and copy text
            targetApp.activate(options: .activateIgnoringOtherApps)
            
            // Wait for activation with consistent timing
            print("DEBUG: Activating target app: \(targetApp.localizedName ?? "Unknown")")
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            
            print("DEBUG: Attempting to copy text from focused element via AccessibilityHelper...")
            guard let externalText = AccessibilityHelper.copyTextFromFocusedElement(targetApplication: targetApp),
                  !externalText.isEmpty else {
                print("No text available from the external app's selection.")
                print("DEBUG: rewriteInPlace FAILED - AccessibilityHelper.copyTextFromFocusedElement returned nil or empty.")
                isProcessing = false
                return
            }
            print("DEBUG: AccessibilityHelper captured text (length: \(externalText.count)) = '\(String(externalText.prefix(100)))...'")
            
            print("Successfully captured text of length: \(externalText.count)")
            print("Captured text preview: \(String(externalText.prefix(50)))...")
            
            await MainActor.run {
                appState.selectedText = externalText
                appState.lastClipboardType = .text
            }
            
            // Step 2: Build the prompt with special handling for spreadsheets
            let instructions = userInput
            print("DEBUG: Instructions for AI: \(instructions)") // Log instructions
            userInput = "" // Clear input after capturing instructions
            
            // Detect if this is an image editing request
            let isImageEditRequest = detectImageEditRequest(instructions)
            
            // --- CHANGED: Only include lastGeneratedImage if it's an explicit edit request ---
            var imagesToInclude: [Data] = []
            if isImageEditRequest, let lastImage = lastGeneratedImage {
                print("Image edit request detected in rewrite mode - including last generated image")
                imagesToInclude.append(lastImage)
            }
            // --- END CHANGED ---
            
            // Detect if content appears to be tabular/CSV data
            let containsTabsOrCommas = externalText.contains("\t") || 
                                       (externalText.contains(",") && externalText.contains("\n"))
            let looksLikeTableData = containsTabsOrCommas || isSpreadsheetApp
            
            let formatInstructions = looksLikeTableData ? 
                "Important: Preserve the table structure exactly. Maintain all tabs, commas, and line breaks in their original positions. If this is spreadsheet data, ensure each cell's content is modified while keeping the overall format intact." : ""
            
            // Create system prompt and final prompt based on whether this is an image edit
            let systemPrompt: String?
            let finalPrompt: String
            
            if isImageEditRequest && lastGeneratedImage != nil {
                systemPrompt = """
                You are an AI that can generate new images based on reference images. The user has attached an image and wants you to create a new version with specific changes.
                When you receive an image along with a request for modifications:
                1. Examine the attached image carefully
                2. Create a NEW image that incorporates the requested changes 
                3. Return the newly generated image
                
                Your strength is in generating images based on examples and descriptions.
                """
                
                finalPrompt = """
                I've attached an image and I'd like you to create a new version with these changes: \(instructions)
                
                Please use the attached image as a reference and create a new image that incorporates these modifications.
                The new image should maintain the overall essence of the original but with the requested changes applied.
                """
            } else {
                systemPrompt = nil
                finalPrompt = """
                Follow instructions of the user (return only the rewritten text, no disclaimers).
                
                \(formatInstructions)

                Instructions: \(instructions)

                Original Text:
                \(externalText)
                """
            }
            
            do {
                // Step 3: Send the prompt to the LLM
                let aiResponse = try await appState.activeProvider.processText(
                    systemPrompt: systemPrompt,
                    userPrompt: finalPrompt,
                    images: imagesToInclude,
                    videos: appState.selectedVideos
                )
                
                // --- REVERTED TO OLD LOGIC: Handle images OR text replacement separately ---
                // Check if there are images in the response
                if !aiResponse.images.isEmpty {
                    // Store the most recent generated image for potential future edits
                    if let latestImage = aiResponse.images.last {
                        lastGeneratedImage = latestImage
                    }
                    
                    // If there are images, display them in a ResponseWindow
                    DispatchQueue.main.async {
                        print("Rewrite: Creating response window with \(aiResponse.images.count) images")
                        
                        let responseView = ResponseView(
                            content: aiResponse.text,
                            selectedText: externalText,
                            option: WritingOption.general,
                            images: aiResponse.images,
                            providerName: aiResponse.providerName,
                            pccTranscriptName: aiResponse.pccTranscriptName
                        )
                        
                        let window = ResponseWindow(
                            with: responseView,
                            title: "AI Generated Image",
                            hasImages: !aiResponse.images.isEmpty
                        )
                        
                        WindowManager.shared.addResponseWindow(window)
                        
                        // Add a message to the chat including the image data
                        self.chatMessages.append((
                            id: UUID(),
                            message: "Assistant: \(aiResponse.text.isEmpty ? "Image successfully generated" : aiResponse.text)",
                            images: aiResponse.images
                        ))
                        
                        // Reactivate our app to show the image window
                        print("Activating app to show image window.")
                        ourApp.activate(options: .activateIgnoringOtherApps)
                    }
                } else if isImageEditRequest && lastGeneratedImage != nil {
                    // Handle the case where an image edit was requested but no image was returned
                    // (This part matches the old logic too)
                    DispatchQueue.main.async {
                        print("Rewrite: Image edit request acknowledged but no modified image was returned")
                        
                        let limitationMessage = """
                        I attempted to create a modified version of the image based on your request, but wasn't able to generate a new image.
                        
                        Please try asking for the modification in a different way, such as:
                        
                        "Create a version of this image with a blue background"
                        "Transform this image to have a more cartoon-like style"
                        "Make a similar image but with mountains in the background"
                        
                        This often works better with more specific, descriptive instructions.
                        """
                        
                        self.chatMessages.append((
                            id: UUID(),
                            message: "Assistant: \(limitationMessage)",
                            images: []
                        ))
                        
                        // Reactivate our app to show the message
                        print("Activating app to show limitation message.")
                        ourApp.activate(options: .activateIgnoringOtherApps)
                    }
                } else {
                    // --- THIS IS THE PURE TEXT REPLACEMENT PATH --- 
                    print("DEBUG: Entered text replacement 'else' block.") // Log entry
                    DispatchQueue.main.async {
                        // Make sure target app is still available
                        if targetApp.isTerminated {
                            print("Target application was closed. Copying result to clipboard instead.")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(aiResponse.text, forType: .string)
                        } else {
                            // Log the text that's about to be pasted
                            if aiResponse.text.isEmpty {
                                print("DEBUG: AI response text is EMPTY. Cannot paste.")
                            } else {
                                print("DEBUG: AI response text (length: \(aiResponse.text.count)) = '\(aiResponse.text.prefix(100))...'")
                            }
                            
                            // For spreadsheet apps, add a slightly longer delay before pasting
                            if isSpreadsheetApp {
                                // Use Thread.sleep like the old version for simplicity here
                                Thread.sleep(forTimeInterval: 0.2) 
                            }
                            print("Attempting to replace text in focused element...")
                            AccessibilityHelper.replaceTextInFocusedElement(with: aiResponse.text, targetApplication: targetApp)
                            
                            // Reactivate our app after operation completes (like old version)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { 
                                print("Activating app after text replacement attempt.")
                                ourApp.activate(options: .activateIgnoringOtherApps)
                            }
                        }
                    }
                    // --- END PURE TEXT REPLACEMENT PATH ---
                }
                 // --- END REVERTED LOGIC ---

            } catch {
                print("Error rewriting: \(error.localizedDescription)")
                // Ensure our app is reactivated even on error
                DispatchQueue.main.async {
                    ourApp.activate(options: .activateIgnoringOtherApps)
                }
            }
            
            isProcessing = false
        }
    }
    
    /// Copies the chat conversation to the clipboard
    private func copyChatToClipboard() {
        // Format the conversation
        let conversationText = chatMessages.map { item in
            item.message // Each message already includes the role prefix
        }.joined(separator: "\n\n")
        
        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conversationText, forType: .string)
        
        // Add a message to inform the user
        chatMessages.append((
            id: UUID(),
            message: "System: Chat conversation copied to clipboard.",
            images: []
        ))
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
                    .glassButtonStyle(variant: .v8) // Use plain style for list items
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

private struct SelectableAssistantReplyText: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat
    let onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
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
        if textView.string != text {
            textView.string = text
            textView.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            textView.textColor = .labelColor
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: (String) -> Void

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
