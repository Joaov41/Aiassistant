import Foundation

@MainActor
final class CoreAIGemmaDownloader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listing
        case downloading(String)
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var detail = ""

    var isDownloading: Bool {
        switch phase {
        case .listing, .downloading:
            return true
        case .idle, .done, .failed:
            return false
        }
    }

    func download(_ model: CoreAIGemmaModel, into baseDirectory: URL = CoreAIGemmaModelStore.modelsDirectory) async {
        guard !isDownloading else { return }

        let finalDirectory = CoreAIGemmaModelStore.directory(for: model, in: baseDirectory)
        if CoreAIGemmaModelStore.isInstalled(model, in: baseDirectory) {
            phase = .done
            progress = 1
            return
        }

        let stagingDirectory = CoreAIGemmaModelStore.stagingDirectory(for: model, in: baseDirectory)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try fileManager.removeItem(at: stagingDirectory)
            }
            if fileManager.fileExists(atPath: finalDirectory.path) {
                try fileManager.copyItem(at: finalDirectory, to: stagingDirectory)
            } else {
                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            }
            try excludeFromBackup(stagingDirectory)

            phase = .listing
            progress = 0
            var files = try await Self.listFiles(
                repo: model.repo,
                remotePath: model.remotePath,
                allowedLocalPathPrefixes: model.downloadedModelPathPrefixes
            )
            for supportDownload in model.supportDownloads {
                files.append(
                    contentsOf: try await Self.listFiles(
                        repo: model.repo,
                        remotePath: supportDownload.remotePath,
                        localDirectoryName: supportDownload.localDirectoryName,
                        allowedLocalPathPrefixes: supportDownload.requiredFiles
                    )
                )
            }
            guard !files.isEmpty else {
                throw CoreAIGemmaDownloadError.emptyListing
            }
            let pendingFiles = files.filter { file in
                !Self.fileExists(
                    at: stagingDirectory.appendingPathComponent(file.localRelativePath),
                    matchingSize: file.size
                )
            }
            let totalBytes = max(pendingFiles.reduce(Int64(0)) { $0 + $1.size }, 1)
            var completedBytes: Int64 = 0

            if pendingFiles.isEmpty {
                detail = "Verifying cached files."
            }

            for (index, file) in pendingFiles.enumerated() {
                try Task.checkCancellation()
                let localRelativePath = file.localRelativePath
                phase = .downloading(localRelativePath)
                let destination = stagingDirectory.appendingPathComponent(localRelativePath)
                try await downloadFile(file, into: stagingDirectory) { fileBytesWritten in
                    let currentBytes = completedBytes + fileBytesWritten
                    self.progress = min(Double(currentBytes) / Double(totalBytes), 1)
                    self.detail = Self.formatProgress(completedBytes: currentBytes, totalBytes: totalBytes, fileIndex: index + 1, fileCount: pendingFiles.count)
                }
                completedBytes += file.size
                progress = min(Double(completedBytes) / Double(totalBytes), 1)
                detail = Self.formatProgress(completedBytes: completedBytes, totalBytes: totalBytes, fileIndex: index + 1, fileCount: pendingFiles.count)
            }

            guard CoreAIGemmaModelStore.isCompleteInstallation(for: model, in: stagingDirectory) else {
                throw CoreAIGemmaDownloadError.incompleteBundle
            }

            if fileManager.fileExists(atPath: finalDirectory.path) {
                try fileManager.removeItem(at: finalDirectory)
            }
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            try excludeFromBackup(finalDirectory)
            phase = .done
            progress = 1
            detail = "Installed \(model.fullDisplayName)."
        } catch is CancellationError {
            phase = .idle
            progress = 0
            detail = ""
            try? fileManager.removeItem(at: stagingDirectory)
        } catch {
            phase = .failed(error.localizedDescription)
            try? fileManager.removeItem(at: stagingDirectory)
        }
    }

    private static func listFiles(
        repo: String,
        remotePath: String,
        localDirectoryName: String? = nil,
        allowedLocalPathPrefixes: [String] = []
    ) async throws -> [HuggingFaceFile] {
        guard let repoID = repoID(from: repo) else {
            throw CoreAIGemmaDownloadError.invalidRepository
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(repoID)/tree/main/\(remotePath)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        guard let url = components.url else {
            throw CoreAIGemmaDownloadError.invalidRepository
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw CoreAIGemmaDownloadError.listingFailed
        }

        let entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: data)
        return entries
            .filter { $0.type == "file" }
            .map {
                HuggingFaceFile(
                    repoID: repoID,
                    relativePath: $0.path,
                    strippingPrefix: remotePath,
                    localDirectoryName: localDirectoryName,
                    size: $0.size ?? 0
                )
            }
            .filter { file in
                allowedLocalPathPrefixes.isEmpty || allowedLocalPathPrefixes.contains { prefix in
                    file.strippedRelativePath == prefix || file.strippedRelativePath.hasPrefix(prefix + "/")
                }
            }
            .sorted { $0.relativePath < $1.relativePath }
    }

    private func downloadFile(
        _ file: HuggingFaceFile,
        into stagingDirectory: URL,
        onProgress: @escaping @MainActor (Int64) -> Void
    ) async throws {
        let remotePath = file.relativePath
        let localRelativePath = file.localRelativePath
        let destination = stagingDirectory.appendingPathComponent(localRelativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let url = URL(string: "https://huggingface.co/\(file.repoID)/resolve/main/\(remotePath)")!
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let delegate = StreamingDownloadDelegate(
            destination: destination,
            localRelativePath: localRelativePath,
            expectedSize: file.size,
            onProgress: onProgress
        )
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let task = session.dataTask(with: request)
        try await delegate.run(task)
    }

    private static func fileExists(at url: URL, matchingSize expectedSize: Int64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return expectedSize == 0 || size.int64Value == expectedSize
    }

    private static func repoID(from repo: String) -> String? {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host?.hasSuffix("huggingface.co") == true {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            return "\(parts[0])/\(parts[1])"
        }
        let parts = trimmed.split(separator: "/")
        return parts.count == 2 ? trimmed : nil
    }

    private static func formatProgress(completedBytes: Int64, totalBytes: Int64, fileIndex: Int, fileCount: Int) -> String {
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(completed) of \(total) · file \(fileIndex) of \(fileCount)"
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

private struct HuggingFaceTreeEntry: Decodable {
    let type: String
    let path: String
    let size: Int64?
}

private struct HuggingFaceFile {
    let repoID: String
    let relativePath: String
    let strippingPrefix: String
    let localDirectoryName: String?
    let size: Int64

    var strippedRelativePath: String {
        if relativePath == strippingPrefix {
            return (relativePath as NSString).lastPathComponent
        } else if relativePath.hasPrefix(strippingPrefix + "/") {
            return String(relativePath.dropFirst(strippingPrefix.count + 1))
        } else {
            return relativePath
        }
    }

    var localRelativePath: String {
        if let localDirectoryName {
            return "\(localDirectoryName)/\(strippedRelativePath)"
        }
        return strippedRelativePath
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let localRelativePath: String
    private let expectedSize: Int64
    private let onProgress: @MainActor (Int64) -> Void
    private var handle: FileHandle?
    private var downloadedBytes: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?

    init(
        destination: URL,
        localRelativePath: String,
        expectedSize: Int64,
        onProgress: @escaping @MainActor (Int64) -> Void
    ) {
        self.destination = destination
        self.localRelativePath = localRelativePath
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    func run(_ task: URLSessionDataTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
            try? FileManager.default.removeItem(at: self.destination)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            finish(.failure(CoreAIGemmaDownloadError.downloadFailed(localRelativePath)))
            completionHandler(.cancel)
            return
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        do {
            handle = try FileHandle(forWritingTo: destination)
            completionHandler(.allow)
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            downloadedBytes += Int64(data.count)
            Task { @MainActor in
                self.onProgress(self.downloadedBytes)
            }
        } catch {
            finish(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        if expectedSize > 0, downloadedBytes != expectedSize {
            finish(.failure(CoreAIGemmaDownloadError.downloadFailed(localRelativePath)))
            return
        }
        Task { @MainActor in
            self.onProgress(self.downloadedBytes)
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        try? handle?.close()
        handle = nil
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

enum CoreAIGemmaDownloadError: LocalizedError {
    case invalidRepository
    case listingFailed
    case emptyListing
    case downloadFailed(String)
    case incompleteBundle

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "The Gemma model repository URL is invalid."
        case .listingFailed:
            return "Unable to list Gemma model files from Hugging Face."
        case .emptyListing:
            return "The Gemma model repository did not return any files."
        case .downloadFailed(let path):
            return "Unable to download Gemma model file: \(path)."
        case .incompleteBundle:
            return "The downloaded Gemma model is incomplete, so it was not installed."
        }
    }
}
