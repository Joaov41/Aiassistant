import Foundation
import Combine
import OSLog

@MainActor
final class DocumentViewModel: ObservableObject {
    private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif"]

    @Published var document: RedactedDocument?
    @Published var recognizedEntities: [RecognizedEntity.Label: [RecognizedEntity]] = [:]
    @Published var selectedEntities: Set<RecognizedEntity> = []
    @Published var manualSelections: [String] = []
    @Published var conversationHistory: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var isExtractingEntities = false
    @Published var errorMessage: String?

    var redactionStore: RedactionStore?
    var entityRecognizer: EntityRecognizer?

    var displayText: String {
        let text = document?.redactedText.isEmpty == false ? document?.redactedText ?? "" : document?.originalText ?? ""
        AppLogger.document.debug("displayText accessed length=\(text.count, privacy: .public)")
        return text
    }

    func reset() {
        document = nil
        recognizedEntities = [:]
        selectedEntities = []
        manualSelections = []
        conversationHistory = []
        errorMessage = nil
    }

    func importFile(at url: URL, settings: SettingsStore) async {
        isProcessing = true
        errorMessage = nil
        let start = Date()
        AppLogger.document.info("Import started path=\(url.lastPathComponent, privacy: .public)")
        defer {
            isProcessing = false
            let duration = Date().timeIntervalSince(start)
            AppLogger.document.info("Import finished in \(duration, privacy: .public)s")
        }
        do {
            let ext = url.pathExtension.lowercased()
            let filename = url.lastPathComponent
            var text = ""
            if ext == "eml" {
                AppLogger.document.info("Importing EML file \(filename, privacy: .public)")
                let data = try Data(contentsOf: url)
                text = EMLParser.extractPlainText(from: data)
            } else if ext == "txt" {
                AppLogger.document.info("Importing TXT file \(filename, privacy: .public)")
                text = try String(contentsOf: url, encoding: .utf8)
            } else if ext == "pdf" {
                AppLogger.document.info("Importing PDF file \(filename, privacy: .public)")
                text = PDFTextExtractor.extractText(from: url)
            } else if imageExtensions.contains(ext) {
                AppLogger.document.info("Importing image file \(filename, privacy: .public)")
                text = ImageTextExtractor.extractText(from: url)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw NSError(domain: "ocr", code: -2, userInfo: [NSLocalizedDescriptionKey: "No readable text detected in the selected image."])
                }
            } else {
                throw NSError(domain: "unsupported", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file type \(ext.uppercased())"])
            }
            text = clean(text: text)
            if settings.autoApplyStoredRedactions, let store = redactionStore {
                AppLogger.document.info("Applying stored redactions to \(filename, privacy: .public)")
                text = store.applyStoredRedactions(to: text)
            }
            AppLogger.document.info("Document prepared file=\(filename, privacy: .public) length=\(text.count, privacy: .public)")
            let doc = RedactedDocument(filename: filename, originalText: text, redactedText: text)
            document = doc
            conversationHistory = [ChatMessage(role: .user, content: text)]
        } catch {
            AppLogger.document.error("Import failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func extractEntities(language: String) async {
        guard let entityRecognizer, let document else { return }
        isExtractingEntities = true
        defer { isExtractingEntities = false }
        let results = await Task(priority: .userInitiated) { () -> [RecognizedEntity] in
            entityRecognizer.recognizeEntities(in: document.redactedText, language: language)
        }.value
        let grouped = Dictionary(grouping: results, by: { $0.label })
        recognizedEntities = grouped
    }

    func toggleSelection(for entity: RecognizedEntity) {
        if selectedEntities.contains(entity) {
            selectedEntities.remove(entity)
        } else {
            selectedEntities.insert(entity)
        }
    }

    func applySelectedEntities() {
        guard var workingDocument = document, let store = redactionStore else { return }
        var updatedText = workingDocument.redactedText
        let allEntities = selectedEntities.map { $0.text } + manualSelections
        for entityText in allEntities {
            let tag = store.nextTag(for: entityText)
            updatedText = Self.replace(entityText: entityText, with: tag, in: updatedText)
        }
        workingDocument.redactedText = updatedText
        workingDocument.updatedAt = Date()
        self.document = workingDocument
        selectedEntities.removeAll()
        manualSelections.removeAll()
        if !conversationHistory.isEmpty {
            conversationHistory[0] = ChatMessage(id: conversationHistory[0].id, role: conversationHistory[0].role, content: updatedText, timestamp: Date())
        }
    }

    func applyManualSelection(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        manualSelections.append(text)
        applySelectedEntities()
    }

    func saveRedactedText() -> URL? {
        guard let document else { return nil }
        let text = document.redactedText
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        do {
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateConversation(with message: ChatMessage) {
        conversationHistory.append(message)
    }

    func resetConversationHistory() {
        if let document {
            conversationHistory = [ChatMessage(role: .user, content: document.redactedText)]
        } else {
            conversationHistory = []
        }
    }

    private func clean(text: String) -> String {
        let withoutHTML = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let normalized = withoutHTML.replacingOccurrences(of: "\r", with: "")
        let condensed = normalized.replacingOccurrences(of: "\n{2,}", with: "\n\n", options: .regularExpression)
        return condensed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(entityText: String, with tag: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: entityText)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.replacingOccurrences(of: entityText, with: tag)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: tag)
    }
}
