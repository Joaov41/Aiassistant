import Foundation

struct RecognizedEntity: Identifiable, Hashable {
    enum Label: String, CaseIterable, Hashable, Codable {
        case person = "PERSON"
        case organization = "ORG"
        case location = "GPE"
        case custom = "CUSTOM"
    }

    let id: UUID
    let text: String
    let label: Label
    let confidence: Double

    init(id: UUID = UUID(), text: String, label: Label, confidence: Double) {
        self.id = id
        self.text = text
        self.label = label
        self.confidence = confidence
    }
}
