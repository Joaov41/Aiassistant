import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct FollowUpPanel: View {
    @State private var question: String = ""
    @State private var expandedMessages: Set<UUID> = []

    @EnvironmentObject private var documentViewModel: DocumentViewModel
    @EnvironmentObject private var followUpViewModel: FollowUpViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isExporterPresented = false
    @State private var exportDocument = TextExportDocument(text: "")
    @State private var exportFilename: String = "conversation"

    var body: some View {
        let transcript = conversationTranscript
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Ask Follow-up Questions")
                    .font(.title2)
                Text("Interact with the document using the selected LLM. The assistant sees the redacted version by default.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                questionInput

                if followUpViewModel.isLoading {
                    ProgressView()
                }

                if let error = followUpViewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                }

                actionBar(transcript: transcript, trimmedTranscript: trimmedTranscript)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Assistant Response")
                        .font(.headline)
                    Group {
                        if followUpViewModel.currentResponse.isEmpty {
                            Text("The assistant's response will appear here.")
                        } else {
                            Text(followUpViewModel.currentResponse)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: responseHeight, alignment: .topLeading)
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(12)
                }

                if documentViewModel.conversationHistory.count > 1 {
                    Divider()
                    Text("Conversation History")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(documentViewModel.conversationHistory) { message in
                            historyRow(for: message)
                        }
                    }
                }
            }
            .padding()
            .padding(.top, isCompactLayout ? compactTopPadding : 0)
            .padding(.bottom, isCompactLayout ? 16 : 0)
        }
        .scrollDismissesKeyboard(.interactively)
        .fileExporter(isPresented: $isExporterPresented, document: exportDocument, contentType: .plainText, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result {
                followUpViewModel.errorMessage = error.localizedDescription
            }
            exportDocument = TextExportDocument(text: "")
        }
        .onChange(of: documentViewModel.conversationHistory) { _ in
            expandedMessages.removeAll()
        }
        .navigationBarTitleDisplayMode(isCompactLayout ? .inline : .automatic)
        .navigationTitle(isCompactLayout ? "" : "Follow-up")
    }

    private func submitQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppLogger.ui.info("Follow-up submitted length=\(trimmed.count, privacy: .public)")
        followUpViewModel.ask(question: trimmed, document: documentViewModel)
        question = ""
        dismissKeyboard()
    }

    private var conversationTranscript: String {
        var components: [String] = documentViewModel.conversationHistory.map { message in
            let role = message.role == .user ? "User" : "Assistant"
            return "\(role): \(message.content)"
        }
        let current = followUpViewModel.currentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty,
           followUpViewModel.isLoading || documentViewModel.conversationHistory.last?.content != current {
            components.append("Assistant: \(current)")
        }
        return components.joined(separator: "\n\n")
    }

    private func defaultExportFilename() -> String {
        if let filename = documentViewModel.document?.filename {
            let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            if !base.isEmpty {
                return "\(base)-conversation"
            }
        }
        return "conversation"
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private var questionInput: some View {
        PromptTextView(text: $question) {
            submitQuestion()
        }
        .frame(maxWidth: .infinity)
        .frame(height: questionInputHeight, alignment: .topLeading)
    }

    private var clearButton: some View {
        Button {
            dismissKeyboard()
            AppLogger.ui.info("Follow-up clear tapped")
            question = ""
            followUpViewModel.clear(document: documentViewModel)
        } label: {
            Label("Clear", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && followUpViewModel.currentResponse.isEmpty
                  && followUpViewModel.errorMessage == nil
                  && documentViewModel.conversationHistory.count <= 1)
    }

    private var sendButton: some View {
        Button {
            submitQuestion()
        } label: {
            Label(followUpViewModel.isLoading ? "Thinking..." : "Send", systemImage: "paperplane")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || documentViewModel.document == nil || followUpViewModel.isLoading)
    }

    @ViewBuilder
    private func actionBar(transcript: String, trimmedTranscript: String) -> some View {
        HStack(alignment: .center) {
            Button {
                guard !trimmedTranscript.isEmpty else { return }
                exportDocument = TextExportDocument(text: transcript)
                exportFilename = defaultExportFilename()
                isExporterPresented = true
                AppLogger.ui.info("Export conversation tapped filename=\(exportFilename, privacy: .public)")
                dismissKeyboard()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(trimmedTranscript.isEmpty)

            Spacer(minLength: 24)

            HStack(spacing: 24) {
                sendButton
                clearButton
            }

            Spacer(minLength: 24)

            Button {
                guard !trimmedTranscript.isEmpty else { return }
                AppLogger.ui.info("Copy conversation tapped length=\(transcript.count, privacy: .public)")
                UIPasteboard.general.string = transcript
                dismissKeyboard()
            } label: {
                Label("Copy Conversation", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(trimmedTranscript.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    private var compactTopPadding: CGFloat {
        24
    }

    private var questionInputHeight: CGFloat {
        isCompactLayout ? 96 : 72
    }

    private var responseHeight: CGFloat {
        isCompactLayout ? 220 : 160
    }

    @ViewBuilder
    private func historyRow(for message: ChatMessage) -> some View {
        let isExpanded = expandedMessages.contains(message.id)
        let isTruncated = message.preview != message.content
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(message.role == .user ? "🙋" : "🤖")
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(isExpanded ? message.content : message.preview)
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 3)
                }
                Spacer()
            }

            if isTruncated || isExpanded {
                Button(isExpanded ? "Show Less" : "More") {
                    if isExpanded {
                        expandedMessages.remove(message.id)
                    } else {
                        expandedMessages.insert(message.id)
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
