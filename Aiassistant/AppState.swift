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

class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var appleProvider: AppleIntelligenceProvider
    @Published var pccProvider: FMPCCProvider
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

    /// Tracks whether we've already auto-captured clipboard content after launch.
    var hasInitializedCapture: Bool = false

    /// Clears the in-app clipboard context and the system pasteboard.
    func clearClipboardData() {
        clearConversationContext()
        NSPasteboard.general.clearContents()
    }

    /// Clears attached chat context while leaving the system pasteboard untouched.
    func clearConversationContext() {
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
        switch AppSettings.shared.selectedAIProvider {
        case .localAppleFoundation:
            return appleProvider
        case .applePCC:
            return pccProvider
        }
    }
    
    // MARK: - Initialization
    private init() {
        let pccProvider = FMPCCProvider()
        self.pccProvider = pccProvider
        self.appleProvider = AppleIntelligenceProvider(pccFallbackProvider: pccProvider)
        
        if !appleProvider.isAvailable {
            print("Warning: Apple Intelligence on-device model unavailable — \(appleProvider.availabilityDescription)")
        }
    }
    
    // MARK: - Clipboard Checking
    @discardableResult
    private func populateSelectionFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        self.selectedText = ""
        self.retainedTextContext = ""
        self.selectedImages = []
        self.selectedVideos = []
        self.attachedContentName = nil

        if let rawString = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawString.isEmpty,
           let url = URL(string: rawString),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            lastClipboardType = .url
            self.attachedContentName = rawString
            self.selectedText = "URL: \(rawString)"
            self.retainedTextContext = self.selectedText
            Task {
                do {
                    let fetched = try await self.fetchAndExtractURL(url)
                    await MainActor.run {
                        self.selectedText = "URL: \(rawString)\n\nContent: \(fetched)"
                        self.retainedTextContext = self.selectedText
                        self.selectedImages = []
                        self.selectedVideos = []
                    }
                } catch {
                    print("Error fetching URL in populateSelectionFromPasteboard: \(error)")
                }
            }
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
        lastClipboardType = .none
            self.selectedText = ""
            self.retainedTextContext = ""
            self.selectedImages = []
            self.selectedVideos = []
            self.attachedContentName = nil
    }
    
    // MARK: - Drag and Drop Handling
    func handleDroppedURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            if url.isFileURL {
                handleDroppedFile(url: url)
            }
            return
        }
        
        Task {
            await MainActor.run {
                self.selectedAppForScreenshot = nil
                self.isSelectingAppForCapture = false
                self.lastClipboardType = .url
                self.selectedImages = []
                self.selectedVideos = []
                self.attachedContentName = url.absoluteString
                self.selectedText = "URL: \(url.absoluteString)"
                self.retainedTextContext = self.selectedText
            }
            
            do {
                let fetched = try await self.fetchAndExtractURL(url)
                await MainActor.run {
                    self.selectedText = "URL: \(url.absoluteString)\n\nContent: \(fetched)"
                    self.retainedTextContext = self.selectedText
                }
            } catch {
                print("Error fetching dropped URL \(url): \(error)")
            }
        }
    }
    
    func handleDroppedFile(url: URL, displayName: String? = nil) {
        guard url.isFileURL else {
            handleDroppedURL(url)
            return
        }
        
        Task.detached { [weak self] in
            guard let self else { return }
            let fileName = displayName?.isEmpty == false ? displayName! : url.lastPathComponent
            let standardizedURL = url.standardizedFileURL
            print("DEBUG (handleDroppedFile): Received URL=\(standardizedURL.path), displayName=\(fileName)")
            let accessGranted = standardizedURL.startAccessingSecurityScopedResource()
            let shouldDeleteAfterUse = standardizedURL.path.hasPrefix(FileManager.default.temporaryDirectory.path)
            defer {
                if accessGranted {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
                if shouldDeleteAfterUse {
                    try? FileManager.default.removeItem(at: standardizedURL)
                    print("DEBUG (handleDroppedFile): Cleaned up temporary file \(standardizedURL.lastPathComponent)")
                }
            }
            
            let ext = standardizedURL.pathExtension.lowercased()
            let fileType = (try? standardizedURL.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier
                .flatMap { UTType($0) } ?? UTType(filenameExtension: ext)
            print("DEBUG (handleDroppedFile): ext=\(ext), uti=\(fileType?.identifier ?? "nil")")
            
            do {
                if let fileType, fileType.conforms(to: .pdf) {
                    let data = try Data(contentsOf: standardizedURL)
                    self.handleDroppedPDFData(data, fileName: fileName)
                    print("DEBUG (handleDroppedFile): Treated as PDF")
                    return
                }
                
                if let fileType, fileType.conforms(to: .image) {
                    let data = try Data(contentsOf: standardizedURL)
                    self.handleDroppedImageData(data, fileName: fileName)
                    print("DEBUG (handleDroppedFile): Treated as Image")
                    return
                }
                
                if let fileType, fileType.conforms(to: .movie) || VideoHandler.supportedFormats.contains(ext) {
                    let videoData = VideoHandler.getVideoData(from: standardizedURL) ?? (try? Data(contentsOf: standardizedURL))
                    if let videoData {
                        self.handleDroppedVideoData(videoData, fileName: fileName)
                        print("DEBUG (handleDroppedFile): Treated as Video")
                    } else {
                        print("Unable to load video data from dropped file \(standardizedURL)")
                    }
                    return
                }

                if ext == "eml" {
                    let data = try Data(contentsOf: standardizedURL)
                    if let text = EMLTextExtractor.extract(from: data) {
                        self.handleDroppedText(text, sourceName: fileName, sourceLabel: "EML Content")
                        print("DEBUG (handleDroppedFile): Treated as EML")
                    } else {
                        print("Unable to extract EML text from dropped file \(standardizedURL)")
                    }
                    return
                }
                
                let isLikelyTextFile: Bool = {
                    if let fileType {
                        if fileType.conforms(to: .plainText) || fileType.conforms(to: .text) {
                            return true
                        }
                        if fileType.conforms(to: .utf8PlainText) || fileType.conforms(to: .utf16PlainText) {
                            return true
                        }
                    }
                    let textExtensions: Set<String> = [
                        "txt", "md", "markdown", "rtf", "rtfd", "csv", "json",
                        "log", "xml", "html", "htm", "yaml", "yml", "swift",
                        "py", "js", "ts", "java", "c", "cpp", "m", "mm", "sh"
                    ]
                    return textExtensions.contains(ext)
                }()
                
                if isLikelyTextFile {
                    if let text = try? self.loadTextFromFile(at: standardizedURL) {
                        self.handleDroppedText(text, sourceName: fileName)
                        print("DEBUG (handleDroppedFile): Treated as Text (likely)")
                        return
                    }
                }
                
                if let fileType, fileType.conforms(to: .rtf),
                   let data = try? Data(contentsOf: standardizedURL),
                   let attributed = try? NSAttributedString(
                    data: data,
                    options: [
                        .documentType: NSAttributedString.DocumentType.rtf
                    ],
                    documentAttributes: nil
                   ) {
                    self.handleDroppedText(attributed.string, sourceName: fileName)
                    print("DEBUG (handleDroppedFile): Treated as RTF")
                    return
                }
                
                if let text = try? self.loadTextFromFile(at: standardizedURL) {
                    self.handleDroppedText(text, sourceName: fileName)
                    print("DEBUG (handleDroppedFile): Treated as Text (fallback)")
                    return
                }
                
                print("Unhandled dropped file type for URL: \(standardizedURL)")
            } catch {
                print("Error processing dropped file \(standardizedURL): \(error)")
            }
        }
    }
    
    func handleDroppedImageData(_ data: Data, fileName: String? = nil) {
        DispatchQueue.main.async {
            self.selectedAppForScreenshot = nil
            self.isSelectingAppForCapture = false
            self.lastClipboardType = .image
            self.selectedText = ""
            self.retainedTextContext = ""
            self.selectedVideos = []
            self.attachedContentName = fileName?.isEmpty == false ? fileName : "Image"
            self.selectedImages = [data]
            self.capturedImageForConversation = data
        }
    }
    
    func handleDroppedVideoData(_ data: Data, fileName: String? = nil) {
        DispatchQueue.main.async {
            self.selectedAppForScreenshot = nil
            self.isSelectingAppForCapture = false
            self.lastClipboardType = .video
            self.selectedText = ""
            self.retainedTextContext = ""
            self.selectedImages = []
            self.attachedContentName = fileName?.isEmpty == false ? fileName : "Video"
            self.selectedVideos = [data]
        }
    }
    
    func handleDroppedText(_ text: String, sourceName: String? = nil, sourceLabel: String = "Text File") {
        DispatchQueue.main.async {
            self.selectedAppForScreenshot = nil
            self.isSelectingAppForCapture = false
            self.lastClipboardType = .text
            self.selectedImages = []
            self.selectedVideos = []
            
            if let sourceName, !sourceName.isEmpty {
                self.attachedContentName = sourceName
                self.selectedText = "\(sourceLabel) (\(sourceName)):\n\n\(text)"
                self.retainedTextContext = self.selectedText
                print("DEBUG (handleDroppedText): Updated selectedText for \(sourceName), length=\(text.count)")
            } else {
                self.attachedContentName = nil
                self.selectedText = text
                self.retainedTextContext = ""
                print("DEBUG (handleDroppedText): Updated selectedText (no source name), length=\(text.count)")
            }
        }
    }
    
    func handleDroppedPDFData(_ data: Data, fileName: String?) {
        let text = PDFHandler.extractText(from: data)
        self.handleDroppedPDF(text: text, fileName: fileName)
    }
    
    private func handleDroppedPDF(text: String, fileName: String?) {
        let displayName = (fileName?.isEmpty == false ? fileName! : "PDF Document")
        DispatchQueue.main.async {
            self.selectedAppForScreenshot = nil
            self.isSelectingAppForCapture = false
            self.lastClipboardType = .pdf
            self.selectedImages = []
            self.selectedVideos = []
            self.attachedContentName = displayName
            self.selectedText = "PDF Content (\(displayName)):\n\n\(text)"
            self.retainedTextContext = self.selectedText
            print("DEBUG (handleDroppedPDF): Updated selectedText for \(displayName), length=\(text.count)")
        }
    }
    
    private func loadTextFromFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            .macOSRoman,
            .isoLatin1
        ]
        
        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) {
                print("DEBUG (loadTextFromFile): Decoded using \(encoding) for \(url.lastPathComponent), length=\(string.count)")
                return string
            }
        }
        
        // Fallback: attempt to interpret as UTF-8 even if invalid bytes exist
        let fallback = String(decoding: data, as: UTF8.self)
        print("DEBUG (loadTextFromFile): Used UTF8 fallback for \(url.lastPathComponent), length=\(fallback.count)")
        return fallback
    }
    
    // For scraping HTML
    func processURLFromClipboard() {
        let pb = NSPasteboard.general
        guard let clipboardString = pb.string(forType: .string),
              let url = URL(string: clipboardString),
              (url.scheme == "http" || url.scheme == "https") else {
            print("No valid URL found in clipboard")
            return
        }
        
        isProcessing = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let extractedText = self.extractTextFromHTML(data: data)
                DispatchQueue.main.async {
                    self.selectedText = extractedText
                    self.retainedTextContext = extractedText
                    self.isProcessing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                }
                print("Error processing URL: \(error.localizedDescription)")
            }
        }
    }
    
    /// Convert HTML data to plain text
    func extractTextFromHTML(data: Data) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attrString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attrString.string
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    // MARK: - Optional PDF Handler
    func handlePDFData(_ pdfData: Data) {
        let text = PDFHandler.extractText(from: pdfData)
        selectedText = text
    }

    // This function was inside the extension, keep it as part of the main class now
    func captureExternalSelection() {
        // Reset selected app and the selection mode when capturing external selection
        self.selectedAppForScreenshot = nil
        self.isSelectingAppForCapture = false
        let previousText = self.selectedText
        let previousClipboardType = self.lastClipboardType
        
        self.selectedImages = []
        self.selectedVideos = []
        
        guard let targetApp = previousApplication ?? NSWorkspace.shared.frontmostApplication,
              targetApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            print("DEBUG (captureExternalSelection): No suitable target application for text capture.")
            return
        }
        
        Task.detached { [weak self] in
            guard let self else { return }
            let ourApp = NSRunningApplication.current
            
            targetApp.activate(options: .activateIgnoringOtherApps)
            try? await Task.sleep(nanoseconds: targetApp.isTerminated ? 0 : 350_000_000) // allow UI to catch up
            
            let copiedText = AccessibilityHelper.copyTextFromFocusedElement(targetApplication: targetApp)
            
            await MainActor.run {
                if let copiedText = copiedText, !copiedText.isEmpty {
                    self.selectedText = copiedText
                    self.retainedTextContext = ""
                    self.lastClipboardType = .text
                } else {
                    self.selectedText = previousText
                    self.lastClipboardType = previousClipboardType
                    print("DEBUG (captureExternalSelection): Failed to retrieve text from accessibility copy.")
                }
                
                // Bring our app back to the front once capture completes
                ourApp.activate(options: .activateIgnoringOtherApps)
            }
        }
    }
    
    /// Attempts to capture the window of the selected app and update state.
    /// Should be called from the UI after the user picks an app.
    // This function was inside the extension, keep it as part of the main class now
    func captureSelectedAppWindow(appInfo: AppInfo) {
        print("DEBUG (captureSelectedAppWindow): selected \(appInfo.name), pid=\(appInfo.id)")
        // Reset selection mode flag
        self.isSelectingAppForCapture = false
        self.isProcessing = true // Indicate activity
        self.selectedText = ""   // Clear other selections
        self.retainedTextContext = ""
        self.selectedVideos = []
        self.selectedImages = [] // Clear previous images
        self.capturedScreenshotData = nil
        self.attachedContentName = nil
        self.lastClipboardType = .none // Reset clipboard type initially

        // Check Screen Recording Permissions (Basic Check)
        // A more robust check would use CGRequestScreenCaptureAccess() if needed
        if !CGPreflightScreenCaptureAccess() {
            print("Screen Capture Access: Not granted. Requesting permission...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                print("Screen Capture Access: User denied or did not grant permission.")
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showPermissionAlert = true
                }
                return
            } else {
                print("Screen Capture Access: Permission granted after request.")
            }
        }

        Task { // Perform capture off the main thread
            do {
                print("Attempting capture for PID: \(appInfo.id)")
                let imageData = try await ScreenshotHelper.captureWindow(pid: appInfo.id)

                // Update state on the main thread
                DispatchQueue.main.async {
                    print("Capture successful, updating state.")
                    self.selectedImages = [imageData]
                    self.capturedImageForConversation = imageData
                    self.capturedScreenshotData = imageData
                    self.selectedAppForScreenshot = appInfo
                    self.attachedContentName = "\(appInfo.name) screenshot"
                    self.lastClipboardType = .image
                    self.isProcessing = false
                }

            } catch let error as ScreenCaptureError {
                print("Screenshot capture failed: \(error)")
                // Update state on the main thread
                DispatchQueue.main.async {
                    self.isSelectingAppForCapture = false
                    self.isProcessing = false
                    // Trigger the alert flag for the UI and store app name
                    self.captureErrorAppName = appInfo.name
                    self.showCaptureErrorAlert = true
                }
            } catch {
                print("An unexpected error occurred during screenshot capture: \(error)")
                DispatchQueue.main.async {
                    self.isSelectingAppForCapture = false
                    self.isProcessing = false
                    // Trigger generic error alert in the calling View
                    self.captureErrorAppName = appInfo.name
                    self.showCaptureErrorAlert = true
                }
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
