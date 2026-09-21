import AppKit
import Foundation
import UniformTypeIdentifiers

enum ImportedAttachment {
    case image(Data, String)
    case video(Data, String)
    case document(String, String, String)
}

enum AttachmentImporter {
    static func load(url: URL, displayName: String?) throws -> ImportedAttachment? {
        let fileURL = url.standardizedFileURL
        let name = displayName?.isEmpty == false ? displayName! : fileURL.lastPathComponent
        let accessGranted = fileURL.startAccessingSecurityScopedResource()
        defer { if accessGranted { fileURL.stopAccessingSecurityScopedResource() } }

        let ext = fileURL.pathExtension.lowercased()
        let type = (try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier
            .flatMap(UTType.init) ?? UTType(filenameExtension: ext)

        if type?.conforms(to: .pdf) == true {
            return .document(PDFHandler.extractText(from: try Data(contentsOf: fileURL)), name, "PDF Content")
        }
        if type?.conforms(to: .image) == true {
            return .image(try Data(contentsOf: fileURL), name)
        }
        if type?.conforms(to: .movie) == true || VideoHandler.supportedFormats.contains(ext) {
            guard let data = VideoHandler.getVideoData(from: fileURL) ?? (try? Data(contentsOf: fileURL)) else {
                return nil
            }
            return .video(data, name)
        }
        if ext == "eml" {
            guard let text = EMLTextExtractor.extract(from: try Data(contentsOf: fileURL)) else { return nil }
            return .document(text, name, "EML Content")
        }
        if type?.conforms(to: .rtf) == true {
            let attributed = try NSAttributedString(
                data: Data(contentsOf: fileURL),
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return .document(attributed.string, name, "Text File")
        }

        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "rtfd", "csv", "json", "log", "xml", "html", "htm",
            "yaml", "yml", "swift", "py", "js", "ts", "java", "c", "cpp", "m", "mm", "sh"
        ]
        if type?.conforms(to: .plainText) == true || type?.conforms(to: .text) == true || textExtensions.contains(ext) {
            return .document(try decodeText(at: fileURL), name, "Text File")
        }
        return nil
    }

    private static func decodeText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .macOSRoman, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
