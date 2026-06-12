import Foundation

struct LLMChunk: Identifiable {
    enum Kind {
        case token(String)
        case status(String)
        case final(String)
    }

    let id = UUID()
    let kind: Kind
}
