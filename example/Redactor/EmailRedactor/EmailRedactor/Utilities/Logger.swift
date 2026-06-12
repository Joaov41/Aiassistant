import OSLog

struct AppLogger {
    static let subsystem = "com.redactor.app"
    static let llm = Logger(subsystem: subsystem, category: "LLM")
    static let document = Logger(subsystem: subsystem, category: "Document")
    static let ui = Logger(subsystem: subsystem, category: "UI")
}
