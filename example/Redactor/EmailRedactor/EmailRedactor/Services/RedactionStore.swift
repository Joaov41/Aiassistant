import Foundation
import SQLite3
import OSLog

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class RedactionStore {
    private let dbPointer: OpaquePointer?
    private let queue = DispatchQueue(label: "redaction.store.queue")

    init(databaseName: String = "redactions.sqlite") {
        let url = Self.databaseURL(databaseName: databaseName)
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            print("[DB] Unable to open database at \(url.path)")
            self.dbPointer = nil
            return
        }
        self.dbPointer = db
        createTables()
    }

    deinit {
        if let dbPointer {
            sqlite3_close(dbPointer)
        }
    }

    private func createTables() {
        let statement = """
        CREATE TABLE IF NOT EXISTS redactions (
            original TEXT PRIMARY KEY,
            tag TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        queue.sync {
            guard let dbPointer else { return }
            if sqlite3_exec(dbPointer, statement, nil, nil, nil) != SQLITE_OK {
                let errorMessage = String(cString: sqlite3_errmsg(dbPointer))
                print("[DB] Failed to create tables: \(errorMessage)")
            }
        }
    }

    func upsertRedaction(original: String, tag: String, updatedAt: Date = Date()) {
        let query = "INSERT OR REPLACE INTO redactions (original, tag, updated_at) VALUES (?, ?, ?);"
        queue.sync {
            guard let dbPointer else { return }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(dbPointer, query, -1, &statement, nil) == SQLITE_OK else {
                AppLogger.document.error("Failed to prepare upsert: \(self.lastErrorMessage(), privacy: .public)")
                return
            }
            sqlite3_bind_text(statement, 1, original, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, tag, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 3, updatedAt.timeIntervalSince1970)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.document.error("Failed to execute upsert: \(self.lastErrorMessage(), privacy: .public)")
            }
        }
    }

    func importRedactions(from url: URL) throws -> Int {
        var externalDB: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &externalDB, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let externalDB else {
            let messagePtr = sqlite3_errmsg(externalDB)
            let message = messagePtr.flatMap { String(cString: $0) } ?? "Unknown error"
            AppLogger.document.error("Failed to open external redaction DB: \(message, privacy: .public)")
            throw NSError(domain: "RedactionStore", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(externalDB) }

        var query = "SELECT original, tag, updated_at FROM redactions"
        var statement: OpaquePointer?
        var preparationResult = sqlite3_prepare_v2(externalDB, query, -1, &statement, nil)
        var includesUpdatedAt = true
        if preparationResult != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(externalDB))
            if message.contains("no such column: updated_at") {
                AppLogger.document.info("External DB missing updated_at column; falling back to legacy schema")
                sqlite3_finalize(statement)
                statement = nil
                query = "SELECT original, tag FROM redactions"
                includesUpdatedAt = false
                preparationResult = sqlite3_prepare_v2(externalDB, query, -1, &statement, nil)
            }
        }
        guard preparationResult == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(externalDB))
            AppLogger.document.error("Failed to prepare import query: \(message, privacy: .public)")
            throw NSError(domain: "RedactionStore", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }

        var imported: [(String, String, Date?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let originalCS = sqlite3_column_text(statement, 0),
                  let tagCS = sqlite3_column_text(statement, 1) else { continue }
            let original = String(cString: originalCS)
            let tag = String(cString: tagCS)
            var updatedAt: Date? = nil
            if includesUpdatedAt, sqlite3_column_count(statement) > 2 && sqlite3_column_type(statement, 2) != SQLITE_NULL {
                let timestamp = sqlite3_column_double(statement, 2)
                updatedAt = Date(timeIntervalSince1970: timestamp)
            }
            imported.append((original, tag, updatedAt))
        }

        AppLogger.document.info("Importing \(imported.count, privacy: .public) redactions from \(url.lastPathComponent, privacy: .public)")
        for entry in imported {
            upsertRedaction(original: entry.0, tag: entry.1, updatedAt: entry.2 ?? Date())
        }
        return imported.count
    }

    func tag(for original: String) -> String? {
        let query = "SELECT tag FROM redactions WHERE original = ? LIMIT 1;"
        return queue.sync {
            guard let dbPointer else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(dbPointer, query, -1, &statement, nil) == SQLITE_OK else {
                print("[DB] Failed to prepare tag lookup: \(lastErrorMessage())")
                return nil
            }
            sqlite3_bind_text(statement, 1, original, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let cString = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: cString)
        }
    }

    func original(for tag: String) -> String? {
        let query = "SELECT original FROM redactions WHERE tag = ? LIMIT 1;"
        return queue.sync {
            guard let dbPointer else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(dbPointer, query, -1, &statement, nil) == SQLITE_OK else {
                print("[DB] Failed to prepare original lookup: \(lastErrorMessage())")
                return nil
            }
            sqlite3_bind_text(statement, 1, tag, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let cString = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: cString)
        }
    }

    func applyStoredRedactions(to text: String) -> String {
        guard !text.isEmpty else { return text }
        let rows = allRedactions()
        guard !rows.isEmpty else { return text }
        return rows.reduce(text) { partial, row in
            guard let tag = row.tag else { return partial }
            return Self.replaceOccurrences(of: row.original, with: tag, in: partial)
        }
    }

    func deanonymize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let regex = try? NSRegularExpression(pattern: "<ANON_[A-Fa-f0-9]{8}>")
        let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        guard !matches.isEmpty else { return text }
        var output = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let tag = String(output[range])
            if let original = original(for: tag) {
                output.replaceSubrange(range, with: original)
            }
        }
        return output
    }

    func allRedactions() -> [(original: String, tag: String?)] {
        let query = "SELECT original, tag FROM redactions;"
        var items: [(String, String?)] = []
        queue.sync {
            guard let dbPointer else { return }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(dbPointer, query, -1, &statement, nil) == SQLITE_OK else {
                print("[DB] Failed to prepare select: \(lastErrorMessage())")
                return
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let originalCS = sqlite3_column_text(statement, 0) else { continue }
                let original = String(cString: originalCS)
                var tag: String?
                if let tagCS = sqlite3_column_text(statement, 1) {
                    tag = String(cString: tagCS)
                }
                items.append((original, tag))
            }
        }
        return items
    }

    func clear() {
        let query = "DELETE FROM redactions;"
        queue.sync {
            guard let dbPointer else { return }
            if sqlite3_exec(dbPointer, query, nil, nil, nil) != SQLITE_OK {
                print("[DB] Failed to clear table: \(lastErrorMessage())")
            }
        }
    }

    func nextTag(for original: String) -> String {
        if let existing = tag(for: original) {
            return existing
        }
        let tag = "<ANON_\(UUID().uuidString.prefix(8))>"
        upsertRedaction(original: original, tag: tag)
        return tag
    }

    private func lastErrorMessage() -> String {
        guard let dbPointer else { return "unknown error" }
        return String(cString: sqlite3_errmsg(dbPointer))
    }

    private static func replaceOccurrences(of original: String, with tag: String, in text: String) -> String {
        guard !original.isEmpty else { return text }
        let pattern = original
            .replacingOccurrences(of: "\\n", with: "\\s*\\n\\s*")
            .replacingOccurrences(of: "\\r", with: "\\s*\\r\\s*")
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        let regexPattern = "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
            return text.replacingOccurrences(of: original, with: tag)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: tag)
    }

    private static func databaseURL(databaseName: String) -> URL {
        let fileManager = FileManager.default
        let containerURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        if !fileManager.fileExists(atPath: containerURL.path) {
            try? fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        }
        return containerURL.appendingPathComponent(databaseName)
    }
}
