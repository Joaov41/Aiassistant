import Foundation
import NaturalLanguage

final class EntityRecognizer {
    private struct CustomPattern: Codable {
        let label: RecognizedEntity.Label.RawValue
        let phrases: [String]
    }

    private struct EntityKey: Hashable {
        let text: String
        let label: RecognizedEntity.Label
    }

    private var customPhrasesByLanguage: [String: [RecognizedEntity.Label: [String]]] = [:]

    init() {
        loadPatterns()
    }

    func recognizeEntities(in text: String, language: String) -> [RecognizedEntity] {
        guard !text.isEmpty else { return [] }
        var entities: [RecognizedEntity] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        if language.lowercased() == "pt" {
            tagger.setLanguage(.portuguese, range: text.startIndex..<text.endIndex)
        } else {
            tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        }

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: options) { tag, range in
            guard let tag, let label = Self.label(from: tag) else { return true }
            let snippet = String(text[range])
            guard snippet.count > 2 else { return true }
            let entity = RecognizedEntity(text: snippet, label: label, confidence: 0.9)
            entities.append(entity)
            return true
        }

        if let custom = customPhrasesByLanguage[language.lowercased()] {
            for (label, phrases) in custom {
                for phrase in phrases {
                    let matches = Self.matches(of: phrase, in: text)
                    for match in matches {
                        let entity = RecognizedEntity(text: match, label: label, confidence: 0.75)
                        entities.append(entity)
                    }
                }
            }
        }

        var bestByKey: [EntityKey: RecognizedEntity] = [:]
        for entity in entities {
            let key = EntityKey(text: entity.text.lowercased(), label: entity.label)
            if let existing = bestByKey[key], existing.confidence >= entity.confidence {
                continue
            }
            bestByKey[key] = entity
        }
        return Array(bestByKey.values)
    }

    private static func label(from tag: NLTag) -> RecognizedEntity.Label? {
        switch tag {
        case .personalName:
            return .person
        case .placeName:
            return .location
        case .organizationName:
            return .organization
        default:
            return nil
        }
    }

    private func loadPatterns() {
        let bundle = Bundle.main
        ["en", "pt"].forEach { language in
            let filename = "patterns_\(language)"
            guard let url = bundle.url(forResource: filename, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let rawPatterns = try? JSONDecoder().decode([CustomPattern].self, from: data) else { return }

            var languagePatterns: [RecognizedEntity.Label: [String]] = [:]
            for pattern in rawPatterns {
                guard let label = RecognizedEntity.Label(rawValue: pattern.label) else { continue }
                languagePatterns[label, default: []].append(contentsOf: pattern.phrases)
            }
            customPhrasesByLanguage[language] = languagePatterns
        }
    }

    private static func matches(of phrase: String, in text: String) -> [String] {
        guard !phrase.isEmpty else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
