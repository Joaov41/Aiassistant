import Foundation

struct RedactedDocument: Identifiable, Codable {
    let id: UUID
    var filename: String
    var originalText: String
    var redactedText: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), filename: String, originalText: String, redactedText: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.filename = filename
        self.originalText = originalText
        self.redactedText = redactedText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
