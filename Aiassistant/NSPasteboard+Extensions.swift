import AppKit
import UniformTypeIdentifiers

extension NSPasteboard {
    var hasPDF: Bool {
        // First, try reading URL objects to see if a file URL with a .pdf extension exists.
        if let urls = self.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            if urls.contains(where: { $0.pathExtension.lowercased() == "pdf" }) {
                return true
            }
        }
        // Fallback: check the available types.
        return types?.contains(where: { $0.rawValue.lowercased().contains("pdf") }) ?? false
    }
    
    var hasVideo: Bool {
        return types?.contains(where: {
            $0.rawValue.lowercased().contains("movie") ||
            $0.rawValue.lowercased().contains("video")
        }) ?? false
    }
    
    var hasImage: Bool {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("public.image")
        ]
        return types?.contains(where: { imageTypes.contains($0) }) ?? false
    }
    
    /// Attempts to load image data from the pasteboard either directly or via file URLs.
    func readImage() -> Data? {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("public.image")
        ]
        
        for type in imageTypes {
            if let data = self.data(forType: type) {
                return data
            }
        }
        
        let imageUTTypes = [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.tiff.identifier,
            UTType.gif.identifier,
            UTType.image.identifier
        ]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: imageUTTypes
        ]
        
        if let urls = self.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls where url.isFileURL {
                if let data = try? Data(contentsOf: url) {
                    return data
                }
            }
        }
        
        return nil
    }
    
    func readPDF() -> Data? {
        // First, try to obtain a PDF file URL using UTType.pdf.
        let pdfUTType = UTType.pdf.identifier
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [pdfUTType]
        ]
        if let urls = self.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let pdfURL = urls.first,
           pdfURL.pathExtension.lowercased() == "pdf",
           let data = try? Data(contentsOf: pdfURL) {
            return data
        }
        
        // Next, check for direct PDF data using known types.
        let pdfTypes: [NSPasteboard.PasteboardType] = [
            .pdf,
            NSPasteboard.PasteboardType("com.adobe.pdf")
        ]
        for type in pdfTypes {
            if let pdfData = self.data(forType: type) {
                return pdfData
            }
        }
        
        return nil
    }
    
    func readVideo() -> Data? {
        let videoTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("public.mpeg-4"),
            NSPasteboard.PasteboardType("com.apple.quicktime-movie"),
            NSPasteboard.PasteboardType("public.avi"),
            NSPasteboard.PasteboardType("public.movie")
        ]
        
        for type in videoTypes {
            if let videoData = self.data(forType: type) {
                return videoData
            }
        }
        
        let readingOptions = [NSPasteboard.ReadingOptionKey.urlReadingContentsConformToTypes: ["public.movie"]]
        if let urls = self.readObjects(forClasses: [NSURL.self], options: readingOptions) as? [URL],
           let firstURL = urls.first,
           VideoHandler.supportedFormats.contains(firstURL.pathExtension.lowercased()),
           let videoData = VideoHandler.getVideoData(from: firstURL) {
            return videoData
        }
        
        return nil
    }

    /// Attempts to load and extract an .eml file referenced by the pasteboard.
    func readEMLContent() -> (text: String, sourceURL: URL)? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["com.apple.mail.email", "public.message"]
        ]
        
        if let urls = self.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls where url.isFileURL && url.pathExtension.lowercased() == "eml" {
                if let text = extractEML(from: url) {
                    return (text, url)
                }
            }
        }
        
        if let potentialPath = self.string(forType: .string),
           FileManager.default.fileExists(atPath: potentialPath) {
            let url = URL(fileURLWithPath: potentialPath)
            if url.pathExtension.lowercased() == "eml",
               let text = extractEML(from: url) {
                return (text, url)
            }
        }

        return nil
    }
    
    /// Attempts to load plain-text content from the pasteboard, including text files referenced by URLs.
    func readPlainTextContent() -> (text: String, sourceURL: URL?)? {
        let pasteboardString = self.string(forType: .string)
        
        let textUTTypes = [
            UTType.plainText.identifier,
            UTType.utf8PlainText.identifier,
            UTType.utf16PlainText.identifier,
            UTType.text.identifier,
            "public.rtf",
            "com.apple.traditional-mac-plain-text",
            "public.html"
        ]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: textUTTypes
        ]
        
        if let urls = self.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls where url.isFileURL {
                if let text = try? loadText(from: url) {
                    return (text, url)
                }
            }
        }
        
        // Handle case where Finder copies provide the file path as a plain string
        if let potentialPath = pasteboardString,
           FileManager.default.fileExists(atPath: potentialPath) {
            let url = URL(fileURLWithPath: potentialPath)
            if let text = try? loadText(from: url) {
                return (text, url)
            }
        }

        if let directString = pasteboardString, !directString.isEmpty {
            return (directString, nil)
        }
        
        return nil
    }
    
    private func loadText(from url: URL) throws -> String {
        if let string = try? String(contentsOf: url, encoding: .utf8) {
            return string
        }
        return try String(contentsOf: url)
    }

    private func extractEML(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return EMLTextExtractor.extract(from: data)
    }
}

extension NSPasteboard.PasteboardType {
    static let pdf = NSPasteboard.PasteboardType("com.adobe.pdf")
    static let video = NSPasteboard.PasteboardType("public.movie")
}
