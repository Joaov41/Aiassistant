import SwiftUI
import OSLog

private enum Panel: String, CaseIterable, Identifiable, Hashable {
    case document = "Document"
    case summary = "Summary"
    case followUp = "Follow-up"
    case deanonymizer = "Deanonymizer"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .document: return "doc.text"
        case .summary: return "list.bullet.rectangle"
        case .followUp: return "bubble.left.and.bubble.right"
        case .deanonymizer: return "lock.open"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    @State private var selection: Panel? = .document

    var body: some View {
        NavigationSplitView {
            List(Panel.allCases, selection: $selection) { panel in
                Label(panel.rawValue, systemImage: panel.icon)
                    .tag(panel)
            }
            .navigationTitle("Email Redactor")
            .listStyle(.sidebar)
        } detail: {
            detailView
                .navigationTitle(selection?.rawValue ?? "")
        }
        .onChange(of: selection) { newValue in
            AppLogger.ui.info("Sidebar selection changed to \(newValue?.rawValue ?? "nil", privacy: .public)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentRequestSummary)) { _ in
            selection = .summary
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentRequestFollowUp)) { _ in
            selection = .followUp
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .document, .none:
            DocumentWorkspaceView()
        case .summary:
            SummaryPanel()
        case .followUp:
            FollowUpPanel()
        case .deanonymizer:
            DeanonymizerPanel()
        case .settings:
            SettingsPanel()
        }
    }
}
