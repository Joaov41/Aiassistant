import SwiftUI
import AppKit
import UniformTypeIdentifiers

// --- ADD THIS STRUCT DEFINITION ---
struct AppInfo: Identifiable, Hashable {
    let id: pid_t // Process ID
    let name: String
    let icon: NSImage?
}
// ---------------------------------

/// Represents the recognized content type in the clipboard.
enum ClipboardContentType {
    case url
    case pdf
    case video
    case image
    case text
    case none
}

enum InteractionMode: String, CaseIterable {
    case chat = "Chat"
    case rewrite = "Rewrite in Place"
    // Add more modes if needed
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    let settings: AppSettings
    
    @Published var appleProvider: AppleIntelligenceProvider
    @Published var cloudProvider: PrivateCloudComputeProvider
    @Published var coreAIGemmaProvider: CoreAIGemmaProvider
    @Published var localOpenAIProvider: OpenAICompatibleLocalProvider
    @Published var selectedMode: InteractionMode = .chat
    
    @Published var customInstruction: String = ""
    
    /// The text content extracted from the clipboard or selection
    @Published var selectedText: String = ""

    /// Text extracted from an attached document/URL that should remain available across chat turns.
    @Published var retainedTextContext: String = ""
    
    /// The image data extracted from clipboard or selection
    @Published var selectedImages: [Data] = []
    
    /// The video data extracted from clipboard or selection
    @Published var selectedVideos: [Data] = []

    /// Name of the currently attached dropped file or URL shown in the chat UI.
    @Published var attachedContentName: String? = nil
    
    /// Tracks which content type was last detected on the clipboard
    @Published var lastClipboardType: ClipboardContentType = .none
    
    /// Whether the popup is currently visible
    @Published var isPopupVisible: Bool = false
    
    /// Whether the app is currently processing an AI request
    @Published var isProcessing: Bool = false
    
    /// The previously frontmost application (for returning focus, optional)
    @Published var previousApplication: NSRunningApplication?
    
    /// Any shared string content (optional usage)
    @Published var sharedContent: String? = nil
    
    // --- NEW PROPERTIES for App Screenshot Feature ---
    @Published var isSelectingAppForCapture: Bool = false // Flag to show app selection UI
    @Published var selectedAppForScreenshot: AppInfo? = nil // Store selected app info
    @Published var capturedScreenshotData: Data? = nil // Store captured image data
    @Published var runningApplications: [AppInfo] = [] // List of running apps for selection
    @Published var showPermissionAlert = false
    @Published var showCaptureErrorAlert = false
    @Published var captureErrorAppName: String = ""
    @Published var capturedImageForConversation: Data? = nil
    @Published private(set) var attachmentRevision: UInt = 0
    @Published private(set) var isAttachmentLoading = false
    private var attachmentTask: Task<Void, Never>?

    var conversationContext: ConversationContext {
        ConversationContext(
            text: retainedTextContext.isEmpty ? selectedText : retainedTextContext,
            isDocument: !retainedTextContext.isEmpty,
            images: capturedImageForConversation.map { [$0] } ?? selectedImages,
            videos: selectedVideos
        )
    }

    /// Tracks whether we've already auto-captured clipboard content after launch.
    var hasInitializedCapture: Bool = false

    /// Clears the in-app clipboard context and the system pasteboard.
    func clearClipboardData() {
        clearConversationContext()
        NSPasteboard.general.clearContents()
    }

    /// Clears attached chat context while leaving the system pasteboard untouched.
    func clearConversationContext() {
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentRevision &+= 1
        isAttachmentLoading = false
        isProcessing = false
        selectedText = ""
        retainedTextContext = ""
        selectedImages = []
        selectedVideos = []
        attachedContentName = nil
        capturedImageForConversation = nil
        selectedAppForScreenshot = nil
        capturedScreenshotData = nil
        lastClipboardType = .none
    }

    func setExternalSelection(_ text: String, from application: NSRunningApplication) {
        replaceAttachment(type: .text, name: nil, text: text)
        previousApplication = application
    }

    private func replaceAttachment(
        type: ClipboardContentType,
        name: String?,
        text: String = "",
        retainedText: String = "",
        images: [Data] = [],
        videos: [Data] = [],
        conversationImage: Data? = nil,
        previewImage: Data? = nil,
        expectedRevision: UInt? = nil
    ) {
        if let expectedRevision, expectedRevision != attachmentRevision { return }
        if expectedRevision == nil {
            attachmentTask?.cancel()
            attachmentTask = nil
            attachmentRevision &+= 1
        }
        isAttachmentLoading = false
        isProcessing = false
        selectedAppForScreenshot = nil
        isSelectingAppForCapture = false
        lastClipboardType = type
        attachedContentName = name
        selectedText = text
        retainedTextContext = retainedText
        selectedImages = images
        selectedVideos = videos
        capturedImageForConversation = conversationImage
        capturedScreenshotData = previewImage
    }

    @discardableResult
    func beginAttachmentImport(name: String?, type: ClipboardContentType = .none) -> UInt {
        replaceAttachment(type: type, name: name)
        isAttachmentLoading = true
        return attachmentRevision
    }

    /// Refresh the list of current running applications for screenshot selection
    func updateRunningApplications() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { AppInfo(id: $0.processIdentifier, name: $0.localizedName ?? "Unknown", icon: $0.icon) }
        DispatchQueue.main.async {
            self.runningApplications = apps
        }
    }
    
    /// The application selected by the user for screenshotting (set AFTER capture)
    
    // MARK: - Current Provider
    /// All AI functionality flows through this selected provider.
    var activeProvider: any AIProvider {
        switch settings.selectedAIProvider {
        case .localAppleFoundation:
            return appleProvider
        case .appleCloud:
            return cloudProvider
        case .coreAIGemma:
            return coreAIGemmaProvider
        case .localOpenAI:
            return localOpenAIProvider
        }
    }

    func processWithActiveProvider(
        systemPrompt: String?,
        userPrompt: String,
        images: [Data],
        videos: [Data]?
    ) async throws -> AIResponse {
        let provider = activeProvider
        return try await provider.processText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            images: images,
            videos: videos
        )
    }

    func cancelActiveProvider() {
        appleProvider.cancel()
        cloudProvider.cancel()
        coreAIGemmaProvider.cancel()
        localOpenAIProvider.cancel()
    }
    
    // MARK: - Initialization
    init(settings: AppSettings = .shared, checkModelAvailability: Bool = true) {
        self.settings = settings
        let cloudProvider = PrivateCloudComputeProvider()
        self.cloudProvider = cloudProvider
        self.appleProvider = AppleIntelligenceProvider(cloudFallbackProvider: cloudProvider)
        self.coreAIGemmaProvider = CoreAIGemmaProvider(cloudFallbackProvider: cloudProvider, settings: settings)
        self.localOpenAIProvider = OpenAICompatibleLocalProvider(settings: settings)
        
        if checkModelAvailability, !appleProvider.isAvailable {
            print("Warning: Apple Intelligence on-device model unavailable — \(appleProvider.availabilityDescription)")
        }

    }
    
    // MARK: - Clipboard Checking
    @discardableResult
    private func populateSelectionFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let rawString = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawString.isEmpty,
           let url = URL(string: rawString),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            handleDroppedURL(url)
            return true
        }

        return false
    }
    
    /// Re-check the system clipboard for URLs only.
    /// This also sets `lastClipboardType`, so the UI can show a short label.
    func recheckClipboard() {
        // Reset selected app and the selection mode when checking clipboard
        self.selectedAppForScreenshot = nil
        self.isSelectingAppForCapture = false
        
        let pb = NSPasteboard.general
        if populateSelectionFromPasteboard(pb) {
            return
        }
        
        // If we reach here, there's nothing recognized in the clipboard
        clearConversationContext()
    }
    
    // MARK: - Drag and Drop Handling
    func handleDroppedURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            if url.isFileURL { handleDroppedFile(url: url) }
            return
        }

        let initialText = "URL: \(url.absoluteString)"
        let revision = beginAttachmentImport(name: url.absoluteString, type: .url)
        selectedText = initialText
        retainedTextContext = initialText
        attachmentTask = Task {
            do {
                let fetched = try await fetchAndExtractURL(url)
                try Task.checkCancellation()
                replaceAttachment(
                    type: .url,
                    name: url.absoluteString,
                    text: initialText + "\n\nContent: " + fetched,
                    retainedText: initialText + "\n\nContent: " + fetched,
                    expectedRevision: revision
                )
                attachmentTask = nil
            } catch {
                guard attachmentRevision == revision else { return }
                attachmentTask = nil
                isAttachmentLoading = false
                guard !Task.isCancelled else { return }
                print("Error fetching dropped URL: \(error.localizedDescription)")
            }
        }
    }

    func handleDroppedFile(url: URL, displayName: String? = nil, deleteAfterImport: Bool = false) {
        guard url.isFileURL else {
            handleDroppedURL(url)
            return
        }
        let revision = beginAttachmentImport(name: displayName ?? url.lastPathComponent)
        attachmentTask = Task.detached {
            defer {
                if deleteAfterImport { try? FileManager.default.removeItem(at: url) }
            }
            do {
                let attachment = try AttachmentImporter.load(url: url, displayName: displayName)
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.attachmentRevision == revision else { return }
                    self.attachmentTask = nil
                    if let attachment {
                        self.applyImportedAttachment(attachment, expectedRevision: revision)
                    } else {
                        self.isAttachmentLoading = false
                        print("Unsupported dropped file: \(url.lastPathComponent)")
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.attachmentRevision == revision else { return }
                    self.attachmentTask = nil
                    self.isAttachmentLoading = false
                    guard !Task.isCancelled else { return }
                    print("Error processing dropped file: \(error.localizedDescription)")
                }
            }
        }
    }

    func applyImportedAttachment(_ attachment: ImportedAttachment, expectedRevision: UInt) {
        switch attachment {
        case .image(let data, let name):
            replaceAttachment(
                type: .image, name: name, images: [data],
                conversationImage: data, previewImage: data, expectedRevision: expectedRevision
            )
        case .video(let data, let name):
            replaceAttachment(type: .video, name: name, videos: [data], expectedRevision: expectedRevision)
        case .document(let content, let name, let label):
            let text = "\(label) (\(name)):\n\n\(content)"
            let type: ClipboardContentType = label == "PDF Content" ? .pdf : .text
            replaceAttachment(type: type, name: name, text: text, retainedText: text, expectedRevision: expectedRevision)
        }
    }

    func handleDroppedImageData(_ data: Data, fileName: String? = nil) {
        replaceAttachment(
            type: .image,
            name: fileName?.isEmpty == false ? fileName : "Image",
            images: [data],
            conversationImage: data,
            previewImage: data
        )
    }

    func handleDroppedVideoData(_ data: Data, fileName: String? = nil) {
        replaceAttachment(
            type: .video,
            name: fileName?.isEmpty == false ? fileName : "Video",
            videos: [data]
        )
    }

    func handleDroppedText(_ text: String, sourceName: String? = nil, sourceLabel: String = "Text File") {
        let displayedText = sourceName?.isEmpty == false ? "\(sourceLabel) (\(sourceName!)):\n\n\(text)" : text
        replaceAttachment(
            type: .text,
            name: sourceName?.isEmpty == false ? sourceName : nil,
            text: displayedText,
            retainedText: sourceName?.isEmpty == false ? displayedText : ""
        )
    }

    func handleDroppedPDFData(_ data: Data, fileName: String?) {
        let name = fileName?.isEmpty == false ? fileName! : "PDF Document"
        let revision = beginAttachmentImport(name: name, type: .pdf)
        attachmentTask = Task.detached {
            let text = PDFHandler.extractText(from: data)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.attachmentRevision == revision else { return }
                self.attachmentTask = nil
                let displayedText = "PDF Content (\(name)):\n\n\(text)"
                self.replaceAttachment(
                    type: .pdf, name: name, text: displayedText,
                    retainedText: displayedText, expectedRevision: revision
                )
            }
        }
    }
    
    // For scraping HTML
    func processURLFromClipboard() {
        guard let rawValue = NSPasteboard.general.string(forType: .string),
              let url = URL(string: rawValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        handleDroppedURL(url)
    }

    func extractTextFromHTML(data: Data) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string)
            ?? String(data: data, encoding: .utf8)
            ?? ""
    }

    func handlePDFData(_ pdfData: Data) {
        handleDroppedPDFData(pdfData, fileName: nil)
    }

    func captureExternalSelection() {
        let previousText = selectedText
        let previousType = lastClipboardType
        guard let targetApp = previousApplication ?? NSWorkspace.shared.frontmostApplication,
              targetApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }
        let revision = beginAttachmentImport(name: nil, type: .text)
        attachmentTask = Task {
            targetApp.activate(options: .activateIgnoringOtherApps)
            try? await Task.sleep(for: .milliseconds(targetApp.isTerminated ? 0 : 350))
            guard !Task.isCancelled else { return }
            let copiedText = await AccessibilityHelper.copyTextFromFocusedElement(targetApplication: targetApp)
            guard attachmentRevision == revision else { return }
            attachmentTask = nil
            if let copiedText, !copiedText.isEmpty {
                replaceAttachment(type: .text, name: nil, text: copiedText, expectedRevision: revision)
                previousApplication = targetApp
            } else {
                replaceAttachment(type: previousType, name: nil, text: previousText, expectedRevision: revision)
            }
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }
    }

    func captureSelectedAppWindow(appInfo: AppInfo) {
        let revision = beginAttachmentImport(name: "\(appInfo.name) screenshot", type: .image)
        isProcessing = true

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            isProcessing = false
            isAttachmentLoading = false
            showPermissionAlert = true
            return
        }

        attachmentTask = Task {
            do {
                let imageData = try await ScreenshotHelper.captureWindow(pid: appInfo.id)
                try Task.checkCancellation()
                guard attachmentRevision == revision else { return }
                attachmentTask = nil
                replaceAttachment(
                    type: .image,
                    name: "\(appInfo.name) screenshot",
                    images: [imageData],
                    conversationImage: imageData,
                    previewImage: imageData,
                    expectedRevision: revision
                )
                selectedAppForScreenshot = appInfo
                isProcessing = false
            } catch {
                guard attachmentRevision == revision else { return }
                attachmentTask = nil
                isSelectingAppForCapture = false
                isProcessing = false
                isAttachmentLoading = false
                guard !Task.isCancelled else { return }
                captureErrorAppName = appInfo.name
                showCaptureErrorAlert = true
            }
        }
    }

    // MARK: - Clipboard Monitoring
    // ... rest of the code remains the same ...

    // --- ADDED: Helper to fetch and extract URL content ---
    func fetchAndExtractURL(_ url: URL) async throws -> String {
        print("DEBUG: Starting fetch for URL: \(url)")
        // Add a timeout to the request (e.g., 15 seconds)
        let request = URLRequest(url: url, timeoutInterval: 15.0)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("ERROR: Invalid HTTP response: \(statusCode)")
            throw URLError(.badServerResponse)
        }
        
        print("DEBUG: Fetch complete (status: \(httpResponse.statusCode)), extracting text...")
        let extractedText = self.extractTextFromHTML(data: data)
        print("DEBUG: Extraction complete (length: \(extractedText.count))")
        return extractedText
    }
    // --- END ADDED ---
}
