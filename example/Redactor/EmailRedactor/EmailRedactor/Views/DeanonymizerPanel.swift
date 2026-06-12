import SwiftUI
import OSLog
import UniformTypeIdentifiers
import UIKit

struct DeanonymizerPanel: View {
    @EnvironmentObject private var viewModel: DeanonymizerViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isExporterPresented = false
    @State private var exportDocument = TextExportDocument(text: "")
    @State private var exportFilename: String = "deanonymized"
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Deanonymizer")
                    .font(.title2)
                Text("Restore original values for previously anonymized text using local redaction history.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: Binding(get: {
                    viewModel.input
                }, set: { newValue in
                    viewModel.input = newValue
                }))
                    .frame(height: inputHeight)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                    .focused($isInputFocused)

                actionButtons

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                }

                if viewModel.output.isEmpty {
                    Text("Deanonymized output will appear here.")
                        .frame(maxWidth: .infinity, minHeight: outputHeight, alignment: .topLeading)
                        .padding()
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                } else {
                    SelectableTextView(text: Binding(get: {
                        viewModel.output
                    }, set: { _ in }), onSelection: { _ in })
                    .frame(minHeight: outputHeight)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                }
            }
            .padding()
            .padding(.top, isCompactLayout ? compactTopPadding : 0)
            .padding(.bottom, isCompactLayout ? 16 : 0)
        }
        .scrollDismissesKeyboard(.interactively)
        .fileExporter(isPresented: $isExporterPresented, document: exportDocument, contentType: .plainText, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result {
                viewModel.errorMessage = error.localizedDescription
            }
            exportDocument = TextExportDocument(text: "")
        }
        .navigationBarTitleDisplayMode(isCompactLayout ? .inline : .automatic)
        .navigationTitle(isCompactLayout ? "" : "Deanonymizer")
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private var compactTopPadding: CGFloat {
        24
    }

    private var inputHeight: CGFloat {
        if viewModel.output.isEmpty {
            return isCompactLayout ? 200 : 140
        }
        return isCompactLayout ? 120 : 100
    }

    private var outputHeight: CGFloat {
        if viewModel.output.isEmpty {
            return isCompactLayout ? 260 : 220
        }
        return isCompactLayout ? 320 : 260
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(alignment: .center, spacing: 24) {
            Button {
                AppLogger.ui.info("Deanonymize tapped inputLength=\(viewModel.input.count, privacy: .public)")
                viewModel.deanonymize()
                dismissKeyboard()
            } label: {
                Label(viewModel.isProcessing ? "Processing..." : "Deanonymize", systemImage: "lock.open")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isProcessing || viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                AppLogger.ui.info("Deanonymizer reset requested")
                viewModel.reset()
                dismissKeyboard()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(viewModel.isProcessing || (viewModel.input.isEmpty && viewModel.output.isEmpty && viewModel.errorMessage == nil))

            Button {
                guard !viewModel.output.isEmpty else { return }
                exportDocument = TextExportDocument(text: viewModel.output)
                exportFilename = "deanonymized-\(Date().formatted(.iso8601.year().month().day()))"
                isExporterPresented = true
                dismissKeyboard()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(viewModel.output.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
