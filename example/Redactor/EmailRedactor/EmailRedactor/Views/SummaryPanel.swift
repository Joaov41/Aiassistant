import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct SummaryPanel: View {
    @EnvironmentObject private var summaryViewModel: SummaryViewModel
    @EnvironmentObject private var documentViewModel: DocumentViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isExporterPresented = false
    @State private var exportDocument = TextExportDocument(text: "")
    @State private var exportFilename: String = "summary"

    var body: some View {
        let summary = summaryViewModel.summaryText
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 16) {
            Text("Summarize Text")
                .font(.title2)
            Text("Generates a structured summary of the currently loaded document.")
                .font(.caption)
                .foregroundColor(.secondary)
            Group {
                if isCompactLayout {
                    VStack(spacing: 12) {
                        summaryButtons(summary: summary, trimmedSummary: trimmedSummary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        summaryButtons(summary: summary, trimmedSummary: trimmedSummary)
                        Spacer()
                    }
                }
            }
            if summaryViewModel.isLoading {
                ProgressView()
            }
            if let error = summaryViewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
            }
            ScrollView {
                Text(summary.isEmpty ? "Summary will appear here." : summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(12)
            }
            .frame(minHeight: summaryContentMinHeight)
        }
        .padding()
        .fileExporter(isPresented: $isExporterPresented, document: exportDocument, contentType: .plainText, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result {
                summaryViewModel.errorMessage = error.localizedDescription
            }
            exportDocument = TextExportDocument(text: "")
        }
    }

    private func defaultExportFilename() -> String {
        guard let filename = documentViewModel.document?.filename else {
            return "summary"
        }
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return base.isEmpty ? "summary" : "\(base)-summary"
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    @ViewBuilder
    private func summaryButtons(summary: String, trimmedSummary: String) -> some View {
        HStack(alignment: .center) {
            Button {
                let length = documentViewModel.displayText.count
                AppLogger.ui.info("Summarize tapped length=\(length, privacy: .public)")
                summaryViewModel.summarize(text: documentViewModel.displayText)
            } label: {
                Label(summaryViewModel.isLoading ? "Summarizing..." : "Summarize", systemImage: "text.alignleft")
            }
            .buttonStyle(.borderedProminent)
            .disabled(documentViewModel.document == nil || summaryViewModel.isLoading)
            .labelStyle(.iconOnly)

            Spacer(minLength: 24)

            Button {
                NotificationCenter.default.post(name: .documentRequestFollowUp, object: nil)
            } label: {
                Label("Follow-up", systemImage: "bubble.left.and.bubble.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(documentViewModel.document == nil)

            Spacer(minLength: 24)

            Button {
                AppLogger.ui.info("Copy summary tapped length=\(summary.count, privacy: .public)")
                UIPasteboard.general.string = summary
            } label: {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(trimmedSummary.isEmpty)

            Spacer(minLength: 24)

            Button {
                guard !trimmedSummary.isEmpty else { return }
                exportDocument = TextExportDocument(text: summary)
                exportFilename = defaultExportFilename()
                isExporterPresented = true
                AppLogger.ui.info("Export summary tapped filename=\(exportFilename, privacy: .public)")
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(trimmedSummary.isEmpty)
        }
        .frame(maxWidth: isCompactLayout ? .infinity : nil)
    }

    private var summaryContentMinHeight: CGFloat {
        isCompactLayout ? 360 : 280
    }
}

extension Notification.Name {
    static let documentRequestFollowUp = Notification.Name("DocumentRequestFollowUp")
}
