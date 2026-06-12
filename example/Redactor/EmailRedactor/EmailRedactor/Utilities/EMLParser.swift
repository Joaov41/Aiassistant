import Foundation
import CoreFoundation

struct EMLParser {
    static func extractPlainText(from data: Data) -> String {
        guard let rawString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ""
        }
        let boundary = self.detectBoundary(in: rawString)
        if let boundary {
            return extractMultipart(rawString: rawString, boundary: boundary)
        }
        return extractSinglePart(rawString: rawString)
    }

    private static func detectBoundary(in raw: String) -> String? {
        guard let range = raw.range(of: "boundary=") else { return nil }
        let start = range.upperBound
        let remainder = raw[start...]
        if remainder.first == "\"", let closing = remainder.dropFirst().firstIndex(of: "\"") {
            return String(remainder[remainder.index(after: remainder.startIndex)..<closing])
        }
        if let endIndex = remainder.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            return String(remainder[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractMultipart(rawString: String, boundary: String) -> String {
        var plainCandidates: [String] = []
        var htmlCandidates: [String] = []
        collectMultipartSections(rawString: rawString, boundary: boundary, plainCandidates: &plainCandidates, htmlCandidates: &htmlCandidates)
        if let plain = plainCandidates.first(where: { !$0.isEmpty }) {
            return plain
        }
        if let html = htmlCandidates.first(where: { !$0.isEmpty }) {
            return html
        }
        return sanitizeFallback(rawString)
    }

    private static func extractSinglePart(rawString: String) -> String {
        if let part = parseSection(rawString) {
            var plainCandidates: [String] = []
            var htmlCandidates: [String] = []
            processPart(headers: part.headers, body: part.body, plainCandidates: &plainCandidates, htmlCandidates: &htmlCandidates)
            if let plain = plainCandidates.first(where: { !$0.isEmpty }) {
                return plain
            }
            if let html = htmlCandidates.first(where: { !$0.isEmpty }) {
                return html
            }
            return sanitizeFallback(String(part.body))
        }
        return sanitizeFallback(rawString)
    }

    private static func clean<S: StringProtocol>(_ string: S) -> String {
        String(string)
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSection(_ section: String) -> (headers: [String: String], body: Substring)? {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let range = trimmed.range(of: "\r\n\r\n") ?? trimmed.range(of: "\n\n") else {
            return nil
        }
        let headerString = String(trimmed[..<range.lowerBound])
        let body = trimmed[range.upperBound...]
        let headers = parseHeaders(headerString)
        return (headers, body)
    }

    private static func parseHeaders(_ headerString: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        let lines = headerString.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            guard !line.isEmpty else { continue }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let key = currentKey {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                headers[key, default: ""] += " " + value
                continue
            }
            guard let colonRange = line.range(of: ":") else { continue }
            let key = line[..<colonRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[colonRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
            currentKey = key
        }
        return headers
    }

    private static func collectMultipartSections(rawString: String, boundary: String, plainCandidates: inout [String], htmlCandidates: inout [String]) {
        let delimiter = "--\(boundary)"
        let sections = rawString.components(separatedBy: delimiter)
        for section in sections {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "--" else { continue }
            guard let part = parseSection(section) else { continue }
            processPart(headers: part.headers, body: part.body, plainCandidates: &plainCandidates, htmlCandidates: &htmlCandidates)
        }
    }

    private static func processPart(headers: [String: String], body: Substring, plainCandidates: inout [String], htmlCandidates: inout [String]) {
        let contentDisposition = headers["content-disposition"]?.lowercased() ?? ""
        if contentDisposition.contains("attachment") {
            return
        }
        let contentTypeHeader = headers["content-type"] ?? ""
        let (contentType, parameters) = parseContentType(contentTypeHeader)
        let transferEncoding = headers["content-transfer-encoding"]?.lowercased()
        if contentType.hasPrefix("image/") || contentType.hasPrefix("audio/") || contentType.hasPrefix("video/") {
            return
        }
        if contentType.hasPrefix("multipart/"), let nestedBoundary = parameters["boundary"], !nestedBoundary.isEmpty {
            let nestedRaw = String(body)
            collectMultipartSections(rawString: nestedRaw, boundary: nestedBoundary, plainCandidates: &plainCandidates, htmlCandidates: &htmlCandidates)
            return
        }
        if !contentType.isEmpty && !contentType.hasPrefix("text/") {
            return
        }
        if contentType.isEmpty, let encoding = transferEncoding, encoding == "base64" || encoding == "binary" {
            return
        }
        let charset = parameters["charset"] ?? extractCharset(from: contentTypeHeader)
        if contentType == "text/plain" || (contentType.isEmpty && !looksLikeHTML(body)) {
            let decoded = decodeBody(body, encoding: transferEncoding, charset: charset)
            let cleaned = stripSignatureArtifacts(decoded)
            if !cleaned.isEmpty {
                plainCandidates.append(cleaned)
            }
            return
        }
        if contentType == "text/html" || looksLikeHTML(body) {
            let decoded = decodeBody(body, encoding: transferEncoding, charset: charset)
            let stripped = stripHTML(decoded)
            let cleaned = stripSignatureArtifacts(stripped)
            if !cleaned.isEmpty {
                htmlCandidates.append(cleaned)
            }
        }
    }

    private static func parseContentType(_ header: String) -> (String, [String: String]) {
        guard !header.isEmpty else { return ("", [:]) }
        let components = header.split(separator: ";", omittingEmptySubsequences: true)
        guard let typeComponent = components.first else { return ("", [:]) }
        let type = typeComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var parameters: [String: String] = [:]
        for component in components.dropFirst() {
            let parts = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            parameters[key] = value
        }
        return (type, parameters)
    }

    private static func stripHTML(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var working = text
        working = working.replacingOccurrences(of: "(?is)<head[\\s\\S]*?</head>", with: "", options: .regularExpression)
        working = working.replacingOccurrences(of: "(?is)<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
        working = working.replacingOccurrences(of: "(?is)<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
        working = working.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        working = working.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
        working = working.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: "&nbsp;", with: " ")
        working = working.replacingOccurrences(of: "&amp;", with: "&")
        working = working.replacingOccurrences(of: "&lt;", with: "<")
        working = working.replacingOccurrences(of: "&gt;", with: ">")
        working = working.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let collapsed = working
        return clean(collapsed)
    }

    private static func stripSignatureArtifacts(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let imageURLPattern = "https?://[^\\s]+\\.(?:png|jpe?g|gif|bmp|heic|heif)(?:\\?[^\\s]*)?"
        let base64LikeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=|_-$!;:.,")
        let lines = text.components(separatedBy: CharacterSet.newlines)
        var cleanedLines: [String] = []
        for line in lines {
            var working = line
            if working.range(of: "urldefense.com", options: .caseInsensitive) != nil {
                continue
            }
            working = working.replacingOccurrences(of: "\\[cid:[^\\]]+\\]", with: "", options: [.regularExpression, .caseInsensitive])
            working = working.replacingOccurrences(of: "cid:[^\\s>\\]]+", with: "", options: [.regularExpression, .caseInsensitive])
            working = working.replacingOccurrences(of: imageURLPattern, with: "", options: [.regularExpression, .caseInsensitive])
            var trimmed = working.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
                continue
            }
            let noWhitespace = trimmed.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) == nil
            if noWhitespace && trimmed.count >= 20 {
                if trimmed.rangeOfCharacter(from: base64LikeCharacters.inverted) == nil {
                    continue
                }
            }
            let base64Trimmed = trimmed.trimmingCharacters(in: base64LikeCharacters)
            if base64Trimmed.isEmpty && trimmed.count >= 20 {
                continue
            }
            trimmed = trimmed.replacingOccurrences(of: "<>", with: "")
            trimmed = trimmed.replacingOccurrences(of: "[]", with: "")
            trimmed = trimmed.replacingOccurrences(of: "()", with: "")
            if trimmed.isEmpty {
                continue
            }
            cleanedLines.append(trimmed)
        }
        let joined = cleanedLines.joined(separator: "\n")
        return clean(joined)
    }

    private static func sanitizeFallback(_ raw: String) -> String {
        let lines = raw.components(separatedBy: CharacterSet.newlines)
        var filtered: [String] = []
        let headerRegex = try? NSRegularExpression(pattern: "^content-[^:]+:", options: [.caseInsensitive])
        let base64CharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if let headerRegex, headerRegex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
                continue
            }
            if trimmed.hasPrefix("--") {
                continue
            }
            let base64Trimmed = trimmed.trimmingCharacters(in: base64CharacterSet)
            if base64Trimmed.isEmpty && trimmed.count >= 40 {
                continue
            }
            filtered.append(trimmed)
        }
        return stripSignatureArtifacts(filtered.joined(separator: "\n"))
    }

    private static func looksLikeHTML(_ body: Substring) -> Bool {
        let sample = body.prefix(512).lowercased()
        return sample.contains("<html") || sample.contains("<body") || sample.contains("<p") || sample.contains("<div")
    }

    private static func extractCharset(from contentType: String) -> String? {
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else { return nil }
        var charset = contentType[range.upperBound...]
        if let separator = charset.firstIndex(of: ";") {
            charset = charset[..<separator]
        }
        var value = charset.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        } else if value.hasPrefix("'") && value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    private static func decodeBody(_ body: Substring, encoding: String?, charset: String?) -> String {
        let rawBody = String(body)
        let raw = removeSoftLineBreaks(rawBody)
        var candidate: String
        if let encoding {
            switch encoding.lowercased() {
            case "quoted-printable":
                if let data = decodeQuotedPrintable(raw),
                   let decoded = decodeData(data, charset: charset) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    candidate = decoded
                } else {
                    candidate = raw
                }
            case "base64":
                let sanitized = raw.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
                if let data = Data(base64Encoded: sanitized, options: [.ignoreUnknownCharacters]),
                   let decoded = decodeData(data, charset: charset) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    candidate = decoded
                } else {
                    candidate = raw
                }
            default:
                candidate = raw
            }
        } else {
            if let data = raw.data(using: .utf8),
               let decoded = decodeData(data, charset: charset) {
                candidate = decoded
            } else {
                candidate = raw
            }
        }
        let unsplit = removeSoftLineBreaks(candidate)
        let resolved = decodeResidualQuotedPrintable(unsplit, charset: charset)
        return clean(resolved)
    }

    private static func decodeData(_ data: Data, charset: String?) -> String? {
        if let charset, let encoding = stringEncoding(for: charset) {
            return String(data: data, encoding: encoding)
        }
        return nil
    }

    private static func stringEncoding(for charset: String) -> String.Encoding? {
        let trimmed = charset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }

    private static func decodeQuotedPrintable(_ string: String) -> Data? {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let char = string[index]
            if char == "=" {
                let nextIndex = string.index(after: index)
                if nextIndex == string.endIndex { break }
                let nextChar = string[nextIndex]
                if nextChar == "\r" {
                    var skipIndex = string.index(after: nextIndex)
                    if skipIndex < string.endIndex, string[skipIndex] == "\n" {
                        skipIndex = string.index(after: skipIndex)
                    }
                    index = skipIndex
                    continue
                } else if nextChar == "\n" {
                    index = string.index(after: nextIndex)
                    continue
                } else {
                    let hexEnd = string.index(nextIndex, offsetBy: 2, limitedBy: string.endIndex)
                    if let hexEnd, string.distance(from: nextIndex, to: hexEnd) == 2 {
                        let hexString = String(string[nextIndex..<hexEnd])
                        if let value = UInt8(hexString, radix: 16) {
                            data.append(value)
                            index = hexEnd
                            continue
                        }
                    }
                }
                if let ascii = Character("=").asciiValue {
                    data.append(ascii)
                }
                index = nextIndex
            } else {
                if let ascii = char.asciiValue {
                    data.append(ascii)
                } else if let charData = String(char).data(using: .utf8) {
                    data.append(contentsOf: charData)
                }
                index = string.index(after: index)
            }
        }
        return data
    }

    private static func decodeResidualQuotedPrintable(_ text: String, charset: String?) -> String {
        let pattern = "=[0-9A-Fa-f]{2}"
        guard text.range(of: pattern, options: .regularExpression) != nil else {
            return text
        }
        guard let data = decodeQuotedPrintable(text) else {
            return text
        }
        if let decoded = decodeData(data, charset: charset) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return decoded
        }
        return text
    }

    private static func removeSoftLineBreaks(_ text: String) -> String {
        let pattern = "=\\s*(?:\\r\\n|\\n|\\r)"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}
