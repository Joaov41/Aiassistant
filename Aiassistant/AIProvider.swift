import Foundation
import AppKit

struct AIResponse {
    let text: String
    let images: [Data]
    let providerName: String
    let pccTranscriptName: String?
    
    init(
        text: String,
        images: [Data] = [],
        providerName: String = AIProviderKind.localAppleFoundation.fullDisplayName,
        pccTranscriptName: String? = nil
    ) {
        self.text = text
        self.images = images
        self.providerName = providerName
        self.pccTranscriptName = pccTranscriptName
    }
}

protocol AIProvider: ObservableObject {
    var isProcessing: Bool { get set }
    func processText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) async throws -> AIResponse
    func cancel()
}

enum FMPCCProviderError: LocalizedError {
    case fmNotFound
    case invalidImage(Int)
    case processFailed(Int32, String)
    case terminalAutomationFailed(String)
    case emptyResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .fmNotFound:
            return "Apple PCC is unavailable on this Mac."
        case .invalidImage(let index):
            return "Image \(index + 1) could not be prepared for Apple PCC."
        case .processFailed(_, let output):
            if output.localizedCaseInsensitiveContains("PCC inference is not available") {
                return "Apple PCC is unavailable: \(output)"
            }
            if output.localizedCaseInsensitiveContains("quota") || output.localizedCaseInsensitiveContains("rate limit") {
                return "Apple PCC quota is exhausted or rate-limited: \(output)"
            }
            return output.isEmpty ? "Apple PCC failed without an error message." : "Apple PCC failed: \(output)"
        case .terminalAutomationFailed(let output):
            return "Apple PCC needs to run through Terminal on this beta. Terminal automation failed: \(output)"
        case .emptyResponse:
            return "Apple PCC returned an empty response."
        case .cancelled:
            return "Apple PCC request was cancelled."
        }
    }
}

final class FMPCCProvider: ObservableObject, AIProvider {
    @Published var isProcessing = false

    private static let fmURL = URL(fileURLWithPath: "/usr/bin/fm")
    private static let ansiPattern = "\u{001B}\\[[0-9;]*m"
    private static let helperDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".aiassistant-pcc-helper", isDirectory: true)
    private let processQueue = DispatchQueue(label: "red.Aiassistant.FMPCCProvider.process")
    private var currentProcess: Process?
    private var currentTerminalShellPID: Int32?

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.fmURL.path)
    }

    func processText(systemPrompt: String?, userPrompt: String, images: [Data], videos: [Data]?) async throws -> AIResponse {
        try await processText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            images: images,
            videos: videos,
            transcriptName: nil
        )
    }

    func processText(
        systemPrompt: String?,
        userPrompt: String,
        images: [Data],
        videos: [Data]?,
        transcriptName existingTranscriptName: String?
    ) async throws -> AIResponse {
        guard isAvailable else { throw FMPCCProviderError.fmNotFound }

        isProcessing = true
        defer { isProcessing = false }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Aiassistant-FMPCC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var promptText = userPrompt
        if let videos, !videos.isEmpty {
            promptText += "\n\n(Note: the user attached \(videos.count) video file(s), but video analysis is not supported by this Apple PCC path. Answer based on the text and any images, and mention this limitation if relevant.)"
        }

        let transcriptName = existingTranscriptName ?? "Aiassistant-\(UUID().uuidString)"
        var arguments = ["respond", "--model", "pcc", "--no-stream"]
        if existingTranscriptName != nil {
            arguments += ["--load-transcript", Self.transcriptFilePath(for: transcriptName)]
        }
        arguments += ["--save-transcript", transcriptName]
        if let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !systemPrompt.isEmpty {
            arguments += ["--instructions", systemPrompt]
        }
        if !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--text", promptText]
        }

        for (index, imageData) in images.enumerated() {
            guard let pngData = Self.pngData(from: imageData) ?? Self.validImageData(imageData) else {
                throw FMPCCProviderError.invalidImage(index)
            }
            let imageURL = tempDirectory.appendingPathComponent("image-\(index + 1).png")
            try pngData.write(to: imageURL, options: .atomic)
            arguments += ["--image", imageURL.path]
        }

        print("FMPCCProvider: running /usr/bin/fm \(arguments.map(Self.shellDisplayArgument).joined(separator: " "))")
        let result = try await withTaskCancellationHandler {
            let directResult = try await runFM(arguments: arguments)
            if directResult.status != 0, Self.isPCCContextUnavailable(directResult.output) {
                print("FMPCCProvider: direct fm is not PCC-capable in this context; retrying through persistent Terminal helper.")
                return try await runFMViaTerminalHelper(arguments: arguments)
            }
            return directResult
        } onCancel: {
            self.cancel()
        }

        if Task.isCancelled {
            throw FMPCCProviderError.cancelled
        }
        guard result.status == 0 else {
            throw FMPCCProviderError.processFailed(result.status, result.output)
        }
        let cleanedOutput = Self.cleanFMResponse(result.output)
        guard !cleanedOutput.isEmpty else {
            throw FMPCCProviderError.emptyResponse
        }
        return AIResponse(
            text: cleanedOutput,
            providerName: AIProviderKind.applePCC.fullDisplayName,
            pccTranscriptName: transcriptName
        )
    }

    func cancel() {
        let process = processQueue.sync {
            let process = currentProcess
            currentProcess = nil
            return process
        }

        if let process, process.isRunning {
            process.terminate()
        }
        let terminalShellPID = processQueue.sync {
            let pid = currentTerminalShellPID
            currentTerminalShellPID = nil
            return pid
        }
        if let terminalShellPID {
            Self.terminateTerminalJob(shellPID: terminalShellPID)
        }
        isProcessing = false
    }

    static func availabilityDescription() async -> String {
        guard FileManager.default.isExecutableFile(atPath: fmURL.path) else {
            return "Apple PCC is unavailable on this Mac."
        }

        do {
            let result = try await runOneShot(arguments: ["available", "--model", "pcc"])
            if result.status == 0 {
                return stripANSI(result.output).isEmpty ? "PCC model available." : stripANSI(result.output)
            }
            let directOutput = stripANSI(result.output)
            if isPCCContextUnavailable(directOutput) {
                let terminalResult = try await runOneShotViaTerminal(arguments: ["available", "--model", "pcc"])
                if terminalResult.status == 0 {
                    let terminalOutput = stripANSI(terminalResult.output)
                    return terminalOutput.isEmpty ? "PCC model available via Terminal." : "\(terminalOutput) (via Terminal)"
                }
                let terminalOutput = stripANSI(terminalResult.output)
                return terminalOutput.isEmpty ? directOutput : "\(directOutput)\nTerminal fallback: \(terminalOutput)"
            }
            return directOutput.isEmpty ? "PCC model unavailable." : directOutput
        } catch {
            return "Unable to check PCC availability: \(error.localizedDescription)"
        }
    }

    private func runFM(arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Self.fmURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputBuffer = LockedProcessOutput()
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
        }

        setCurrentProcess(process)

        do {
            try process.run()
        } catch {
            fileHandle.readabilityHandler = nil
            clearCurrentProcess(process)
            throw FMPCCProviderError.fmNotFound
        }

        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
        }

        fileHandle.readabilityHandler = nil
        let remainingData = fileHandle.readDataToEndOfFile()
        outputBuffer.append(remainingData)
        let output = outputBuffer.stringValue()

        clearCurrentProcess(process)
        return (status, Self.stripANSI(output))
    }

    private func setCurrentProcess(_ process: Process?) {
        processQueue.sync {
            currentProcess = process
        }
    }

    private func clearCurrentProcess(_ process: Process) {
        processQueue.sync {
            if currentProcess === process {
                currentProcess = nil
            }
        }
    }

    private func setCurrentTerminalShellPID(_ pid: Int32?) {
        processQueue.sync {
            currentTerminalShellPID = pid
        }
    }

    private func runFMViaTerminalHelper(arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Self.ensureTerminalHelperStarted()

        let jobDirectory = Self.helperDirectory
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let scriptURL = jobDirectory.appendingPathComponent("run.zsh")
        let readyURL = jobDirectory.appendingPathComponent("request.ready")
        let outputURL = jobDirectory.appendingPathComponent("output.txt")
        let statusURL = jobDirectory.appendingPathComponent("status.txt")
        let pidURL = jobDirectory.appendingPathComponent("pid.txt")
        let doneURL = jobDirectory.appendingPathComponent("done")

        let command = ([Self.fmURL.path] + arguments).map(Self.shellDisplayArgument).joined(separator: " ")
        let script = """
        #!/bin/zsh
        echo $$ > \(Self.shellDisplayArgument(pidURL.path))
        \(command) > \(Self.shellDisplayArgument(outputURL.path)) 2>&1
        fm_status=$?
        echo $fm_status > \(Self.shellDisplayArgument(statusURL.path))
        touch \(Self.shellDisplayArgument(doneURL.path))
        exit $fm_status
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try Data().write(to: readyURL, options: .atomic)

        for _ in 0..<1200 {
            if FileManager.default.fileExists(atPath: doneURL.path) {
                break
            }
            if let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                setCurrentTerminalShellPID(pid)
            }
            if Task.isCancelled {
                cancel()
                throw FMPCCProviderError.cancelled
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        setCurrentTerminalShellPID(nil)

        guard FileManager.default.fileExists(atPath: doneURL.path) else {
            throw FMPCCProviderError.processFailed(1, "Timed out waiting for Terminal to finish the Apple PCC request.")
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let statusText = (try? String(contentsOf: statusURL, encoding: .utf8)) ?? "1"
        let fmStatus = Int32(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        return (fmStatus, Self.stripANSI(output))
    }

    private static func ensureTerminalHelperStarted() async throws {
        try FileManager.default.createDirectory(
            at: helperDirectory.appendingPathComponent("jobs", isDirectory: true),
            withIntermediateDirectories: true
        )

        let pidURL = helperDirectory.appendingPathComponent("helper.pid")
        if let pid = readPID(from: pidURL), isProcessRunning(pid: pid) {
            return
        }

        try? FileManager.default.removeItem(at: pidURL)
        let helperScriptURL = helperDirectory.appendingPathComponent("helper.zsh")
        let jobsPath = helperDirectory.appendingPathComponent("jobs", isDirectory: true).path
        let helperScript = """
        #!/bin/zsh
        setopt NULL_GLOB
        echo $$ > \(shellDisplayArgument(pidURL.path))
        echo -ne "\\033]0;Aiassistant PCC Helper\\007"
        jobs_dir=\(shellDisplayArgument(jobsPath))
        mkdir -p "$jobs_dir"
        while true; do
          for job_dir in "$jobs_dir"/*; do
            [ -d "$job_dir" ] || continue
            [ -f "$job_dir/request.ready" ] || continue
            [ ! -f "$job_dir/started" ] || continue
            touch "$job_dir/started"
            /bin/zsh "$job_dir/run.zsh" > "$job_dir/helper.log" 2>&1
            touch "$job_dir/done"
          done
          sleep 0.2
        done
        """
        try helperScript.write(to: helperScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperScriptURL.path)

        let appleScript = """
        on run argv
            tell application "Terminal"
                do script "/bin/zsh " & quoted form of item 1 of argv
                delay 0.2
                try
                    set miniaturized of front window to true
                end try
            end tell
        end run
        """
        let launchResult = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript, helperScriptURL.path]
        )
        guard launchResult.status == 0 else {
            throw FMPCCProviderError.terminalAutomationFailed(stripANSI(launchResult.output))
        }

        for _ in 0..<40 {
            if let pid = readPID(from: pidURL), isProcessRunning(pid: pid) {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw FMPCCProviderError.terminalAutomationFailed("Timed out waiting for the persistent PCC helper to start.")
    }

    private static func runOneShot(arguments: [String]) async throws -> (status: Int32, output: String) {
        try await runProcess(executableURL: fmURL, arguments: arguments)
    }

    private static func runOneShotViaTerminal(arguments: [String]) async throws -> (status: Int32, output: String) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Aiassistant-FMPCC-Availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("check-fm-pcc.zsh")
        let outputURL = tempDirectory.appendingPathComponent("output.txt")
        let statusURL = tempDirectory.appendingPathComponent("status.txt")
        let doneURL = tempDirectory.appendingPathComponent("done")

        let command = ([fmURL.path] + arguments).map(shellDisplayArgument).joined(separator: " ")
        let script = """
        #!/bin/zsh
        \(command) > \(shellDisplayArgument(outputURL.path)) 2>&1
        fm_status=$?
        echo $fm_status > \(shellDisplayArgument(statusURL.path))
        touch \(shellDisplayArgument(doneURL.path))
        exit $fm_status
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let appleScript = """
        on run argv
            tell application "Terminal"
                do script "/bin/zsh " & quoted form of item 1 of argv
            end tell
        end run
        """
        let launchResult = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript, scriptURL.path]
        )
        guard launchResult.status == 0 else {
            throw FMPCCProviderError.terminalAutomationFailed(stripANSI(launchResult.output))
        }

        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: doneURL.path) {
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let statusText = (try? String(contentsOf: statusURL, encoding: .utf8)) ?? "1"
                let fmStatus = Int32(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                return (fmStatus, stripANSI(output))
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return (1, "Timed out waiting for Terminal to check PCC availability.")
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func pngData(from data: Data) -> Data? {
        guard
            let image = NSImage(data: data),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func validImageData(_ data: Data) -> Data? {
        NSImage(data: data) == nil ? nil : data
    }

    private static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ansiPattern) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPCCContextUnavailable(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("PCC inference is not available in this context")
    }

    private static func cleanFMResponse(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Session saved:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transcriptFilePath(for transcriptName: String) -> String {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".fm/sessions/\(transcriptName).json")
            .path
    }

    private static func terminateTerminalJob(shellPID: Int32) {
        let shellPIDText = String(shellPID)
        _ = try? runDetachedProcess(executableURL: URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-TERM", "-P", shellPIDText])
        _ = try? runDetachedProcess(executableURL: URL(fileURLWithPath: "/bin/kill"), arguments: ["-TERM", shellPIDText])
    }

    private static func runDetachedProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
    }

    private static func readPID(from url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-0", String(pid)]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func shellDisplayArgument(_ argument: String) -> String {
        if argument.contains(" ") || argument.contains("\n") || argument.contains("'") || argument.contains("\"") {
            return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return argument
    }
}

private final class LockedProcessOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "red.Aiassistant.FMPCCProvider.output")
    private var data = Data()

    func append(_ newData: Data) {
        queue.sync {
            data.append(newData)
        }
    }

    func stringValue() -> String {
        queue.sync {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}
