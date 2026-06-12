import Foundation

enum WritingOption: String, Identifiable {
    case coding = "Coding"
    case general = "General"
    
    var id: String { rawValue }
    
    var systemPrompt: String {
        switch self {
        case .coding:
            return """
            You are a coding assistant. Based on the user's instructions and provided code context, \
            generate or rewrite code to implement the desired functionality. \
            Output ONLY the code with no additional comments or explanations. \
            If the input is completely incompatible (e.g., totally random gibberish), \
            output "ERROR_TEXT_INCOMPATIBLE_WITH_REQUEST".
            """
        case .general:
            return """
            You are a helpful assistant. Respond to the user's question or instruction thoughtfully and comprehensively.
            If the question is unclear, ask for clarification. Use Markdown formatting when appropriate.
            """
        }
    }
    
    var icon: String {
        switch self {
        case .coding:
            return "chevron.left.slash.chevron.right"  // SF Symbol for coding
        case .general:
            return "text.bubble"  // SF Symbol for general chat
        }
    }
}
