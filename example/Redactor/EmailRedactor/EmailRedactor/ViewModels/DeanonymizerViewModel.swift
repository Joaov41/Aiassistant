import Foundation
import Combine
import OSLog

@MainActor
final class DeanonymizerViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var output: String = ""
    @Published var isProcessing = false
    @Published var errorMessage: String?

    var redactionStore: RedactionStore?

    private var deanonymizeTask: Task<Void, Never>?
    private var currentTaskID: UUID?

    func deanonymize() {
        guard let store = redactionStore else {
            errorMessage = "Redaction store unavailable"
            return
        }
        guard !self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let previousID = currentTaskID {
            AppLogger.document.info("Cancelling deanonymizer task id=\(previousID.uuidString, privacy: .public)")
        }
        deanonymizeTask?.cancel()
        isProcessing = true
        errorMessage = nil
        output = ""
        let requestID = UUID()
        currentTaskID = requestID
        let inputLength = self.input.count
        AppLogger.document.info("Starting deanonymize task id=\(requestID.uuidString, privacy: .public) inputLength=\(inputLength, privacy: .public)")

        let currentInput = self.input
        deanonymizeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await Task(priority: .userInitiated) { store.deanonymize(currentInput) }.value
            AppLogger.document.info("Deanonymize task completed id=\(requestID.uuidString, privacy: .public)")
            await MainActor.run {
                guard self.currentTaskID == requestID else { return }
                self.output = result
                self.isProcessing = false
                self.currentTaskID = nil
            }
        }
    }

    func reset() {
        if let id = currentTaskID {
            AppLogger.document.info("Reset deanonymizer cancelling task id=\(id.uuidString, privacy: .public)")
        }
        deanonymizeTask?.cancel()
        deanonymizeTask = nil
        currentTaskID = nil
        input = ""
        output = ""
        errorMessage = nil
        isProcessing = false
    }

    func saveOutput() -> URL? {
        guard !output.isEmpty else { return nil }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("deanonymized-\(UUID().uuidString).txt")
        do {
            try output.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    deinit {
        deanonymizeTask?.cancel()
        if let id = currentTaskID {
            AppLogger.document.info("DeanonymizerViewModel deinitialized while task id=\(id.uuidString, privacy: .public) was active")
        }
    }
}
