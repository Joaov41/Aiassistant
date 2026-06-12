import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    private static func makePreview(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 400 else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 400)
        return String(trimmed[..<index]) + "…"
    }

    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    let preview: String

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.preview = Self.makePreview(from: content)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        preview = Self.makePreview(from: content)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
    }
}
