import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    let settings = SettingsStore()
    let documentViewModel = DocumentViewModel()
    let summaryViewModel = SummaryViewModel()
    let followUpViewModel = FollowUpViewModel()
    let deanonymizerViewModel = DeanonymizerViewModel()

    private let redactionStore = RedactionStore()
    private let entityRecognizer = EntityRecognizer()

    init() {
        documentViewModel.redactionStore = redactionStore
        documentViewModel.entityRecognizer = entityRecognizer
        summaryViewModel.llmService = RemoteLLMService(settings: settings)
        followUpViewModel.llmService = RemoteLLMService(settings: settings)
        deanonymizerViewModel.redactionStore = redactionStore
    }

    func importRedactions(from url: URL) async throws -> Int {
        try await Task(priority: .userInitiated) {
            try self.redactionStore.importRedactions(from: url)
        }.value
    }
}
