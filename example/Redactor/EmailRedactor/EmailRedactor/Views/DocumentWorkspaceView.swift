import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DocumentWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var documentViewModel: DocumentViewModel
    @EnvironmentObject private var summaryViewModel: SummaryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isImporterPresented = false
    @State private var pendingSelection: String = ""
    @State private var isExporterPresented = false
    @State private var exportDocument = TextExportDocument(text: "")
    @State private var exportFilename: String = "redacted"
    @State private var isEntitySheetPresented = false
    @State private var shouldPresentEntitiesAfterExtraction = false
    private let supportedExtensions: Set<String> = ["eml", "txt", "pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif"]
    private let compactBottomBarHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: isCompactLayout ? 16 : 20) {
            header
            if let error = documentViewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
            }
            if let document = documentViewModel.document {
                documentSummary(document: document)
                entitySection
                selectionToolbar
                textViewer
            } else {
                placeholder
            }
        }
        .padding()
        .padding(.top, compactTopPadding)
        .padding(.bottom, isCompactLayout ? compactBottomPadding : 0)
        .onDrop(of: dropContentTypes, isTargeted: nil, perform: handleDrop)
        .fileImporter(isPresented: $isImporterPresented,
                      allowedContentTypes: [.plainText, UTType(filenameExtension: "eml") ?? .data, .pdf, .image],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importDocument(from: url)
            case .failure(let error):
                documentViewModel.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $isExporterPresented, document: exportDocument, contentType: .plainText, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result {
                documentViewModel.errorMessage = error.localizedDescription
            }
            exportDocument = TextExportDocument(text: "")
        }
        .safeAreaInset(edge: .bottom) {
            if isCompactLayout, documentViewModel.document != nil {
                compactBottomBar
            }
        }
        .navigationBarTitleDisplayMode(isCompactLayout ? .inline : .automatic)
        .navigationTitle(isCompactLayout ? "" : "Document")
        .onReceive(documentViewModel.$recognizedEntities) { _ in
            guard isCompactLayout else { return }
            updateEntitySheetPresentation()
        }
        .onReceive(documentViewModel.$document) { _ in
            guard isCompactLayout else { return }
            updateEntitySheetPresentation()
        }
        .sheet(isPresented: Binding(get: {
            isEntitySheetPresented && isCompactLayout
        }, set: { newValue in
            isEntitySheetPresented = newValue
            if !newValue {
                shouldPresentEntitiesAfterExtraction = false
            }
        })) {
            if hasRecognizedEntities {
                EntitySelectionSheet(
                    viewModel: documentViewModel,
                    onRedact: {
                        documentViewModel.applySelectedEntities()
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if isCompactLayout {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                importButton
                newDocumentButton
                extractEntitiesButton
            }
        }
    }

    private func documentSummary(document: RedactedDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(document.filename)
                    .font(.headline)
                Spacer()
                Text("Last updated \(document.updatedAt.formatted())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("Characters: \(document.redactedText.count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var entitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Detected Entities")
                    .font(.title3)
                Spacer()
                if !documentViewModel.selectedEntities.isEmpty {
                    Button("Redact Selected") {
                        documentViewModel.applySelectedEntities()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if documentViewModel.recognizedEntities.isEmpty {
                Text("Run entity extraction to see suggestions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if isCompactLayout {
                Button {
                    isEntitySheetPresented = true
                    shouldPresentEntitiesAfterExtraction = false
                } label: {
                    Label("View Detected Entities", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(RecognizedEntity.Label.allCases, id: \.self) { label in
                            let entities = documentViewModel.recognizedEntities[label] ?? []
                            if !entities.isEmpty {
                                EntityChipGroup(label: label, entities: entities, selection: documentViewModel)
                            }
                        }
                    }
                }
            }
        }
    }

    private var selectionToolbar: some View {
        Group {
            if isCompactLayout {
                VStack(spacing: 12) {
                    if documentViewModel.document != nil {
                        HStack(spacing: 12) {
                            newDocumentButton
                            extractEntitiesButton
                        }
                    }
                    selectionButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    selectionButtons
                }
            }
        }
    }

    private var textViewer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Document Content")
                .font(.title3)
            SelectableTextView(text: Binding(get: {
                documentViewModel.displayText
            }, set: { _ in
                // read-only view
            }), onSelection: { selection in
                pendingSelection = selection
            })
            .frame(minHeight: textViewerHeight, maxHeight: isCompactLayout ? textViewerHeight : 400)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.open")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.secondary)
            Text("Import or drag an .eml, .txt, .pdf, or image file to begin.")
                .font(.headline)
                .foregroundColor(.secondary)
            Button("Import Document") {
                isImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropContentTypes: [UTType] {
        var types: [UTType] = [.fileURL]
        if let emlType = UTType(filenameExtension: "eml") {
            types.append(emlType)
        }
        types.append(contentsOf: [.pdf, .plainText, .data, .image])
        return types
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact && UIDevice.current.userInterfaceIdiom == .phone
    }

    private var hasRecognizedEntities: Bool {
        documentViewModel.recognizedEntities.values.contains { !$0.isEmpty }
    }

    private func updateEntitySheetPresentation() {
        if documentViewModel.document == nil {
            isEntitySheetPresented = false
            shouldPresentEntitiesAfterExtraction = false
            return
        }
        if shouldPresentEntitiesAfterExtraction {
            isEntitySheetPresented = true
            shouldPresentEntitiesAfterExtraction = false
        } else if !hasRecognizedEntities {
            isEntitySheetPresented = false
        }
    }

    private var textViewerHeight: CGFloat {
        if isCompactLayout {
            let screenHeight = UIScreen.main.bounds.height
            return min(max(screenHeight * 0.5, 320), 460)
        }
        return 400
    }

    private var compactTopPadding: CGFloat {
        isCompactLayout ? 84 : 0
    }

    private var compactBottomPadding: CGFloat {
        guard isCompactLayout else { return 0 }
        return documentViewModel.document == nil ? 24 : compactBottomBarHeight
    }

    @ViewBuilder
    private var importButton: some View {
        Button {
            isImporterPresented = true
        } label: {
            Label("Import Document", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: isCompactLayout ? .infinity : nil)
    }

    @ViewBuilder
    private var newDocumentButton: some View {
        Button {
            documentViewModel.reset()
        } label: {
            Label("New Document", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(documentViewModel.document == nil)
        .frame(maxWidth: isCompactLayout ? .infinity : nil)
    }

    @ViewBuilder
    private var extractEntitiesButton: some View {
        Button {
            if isCompactLayout {
                shouldPresentEntitiesAfterExtraction = true
            }
            Task {
                await documentViewModel.extractEntities(language: appState.settings.preferredLanguage)
            }
        } label: {
            Label(documentViewModel.isExtractingEntities ? "Extracting..." : "Extract Entities", systemImage: "target")
        }
        .buttonStyle(.bordered)
        .disabled(documentViewModel.document == nil || documentViewModel.isExtractingEntities)
        .frame(maxWidth: isCompactLayout ? .infinity : nil)
    }

    @ViewBuilder
    private var selectionButtons: some View {
        if !pendingSelection.isEmpty {
            Button {
                documentViewModel.applyManualSelection(pendingSelection)
                pendingSelection = ""
            } label: {
                Label("Redact Selection", systemImage: "eye.slash")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: isCompactLayout ? .infinity : nil, alignment: .leading)
        }
        HStack(alignment: .center) {
            Button {
                guard documentViewModel.document != nil else { return }
                let text = documentViewModel.displayText
                summaryViewModel.summarize(text: text)
                NotificationCenter.default.post(name: .documentRequestSummary, object: nil)
            } label: {
                Label(summaryViewModel.isLoading ? "Summarizing..." : "Summarize", systemImage: "text.alignleft")
            }
            .buttonStyle(.bordered)
            .disabled(documentViewModel.document == nil || summaryViewModel.isLoading)
            .labelStyle(.iconOnly)

            Spacer(minLength: 24)

            Button {
                guard documentViewModel.document != nil else { return }
                NotificationCenter.default.post(name: .documentRequestFollowUp, object: nil)
            } label: {
                Label("Follow-up", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.bordered)
            .disabled(documentViewModel.document == nil)
            .labelStyle(.iconOnly)

            Spacer(minLength: 24)

            Button {
                guard let document = documentViewModel.document else { return }
                exportDocument = TextExportDocument(text: document.redactedText)
                exportFilename = defaultExportFilename(for: document.filename)
                isExporterPresented = true
            } label: {
                Label("Export Redacted", systemImage: "square.and.arrow.up")
            }
            .disabled(documentViewModel.document == nil)
            .labelStyle(.iconOnly)

            Spacer(minLength: 24)

            Button {
                UIPasteboard.general.string = documentViewModel.displayText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(documentViewModel.document == nil)
            .labelStyle(.iconOnly)
        }
        .frame(maxWidth: .infinity)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let identifiers = dropContentTypes.map { $0.identifier }

        guard let provider = providers.first(where: { provider in
            identifiers.contains(where: { provider.hasItemConformingToTypeIdentifier($0) })
        }) else {
            handleDropError("Unsupported drop item.")
            return false
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    self.handleDropError(error.localizedDescription)
                    return
                }

                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else {
                    resolvedURL = nil
                }

                guard let url = resolvedURL else {
                    self.handleDropError("Unable to read dropped file.")
                    return
                }

                self.processDroppedFile(at: url, cleanup: false)
            }
            return true
        }

        guard let identifier = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            handleDropError("Unsupported drop item.")
            return false
        }

        provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
            if let error {
                self.handleDropError(error.localizedDescription)
                return
            }
            guard let url else {
                self.handleDropError("Unable to read dropped file.")
                return
            }
            let extensionHint: String = {
                let existing = url.pathExtension
                if !existing.isEmpty {
                    return existing
                }
                if let suggested = provider.suggestedName,
                   let extSubstring = suggested.split(separator: ".").last,
                   suggested.contains(".") {
                    return String(extSubstring)
                }
                if let utType = UTType(identifier),
                   let ext = utType.preferredFilenameExtension {
                    return ext
                }
                return "tmp"
            }()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(extensionHint)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                self.processDroppedFile(at: destination, cleanup: true)
            } catch {
                self.handleDropError(error.localizedDescription)
            }
        }
        return true
    }

    private func importDocument(from url: URL, cleanup: Bool = false) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
                if cleanup {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            await documentViewModel.importFile(at: url, settings: appState.settings)
        }
    }

    private func processDroppedFile(at url: URL, cleanup: Bool) {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            let message = url.pathExtension.isEmpty ? "Unsupported file type." : "Unsupported file type \(url.pathExtension.uppercased())."
            handleDropError(message)
            if cleanup {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }

        importDocument(from: url, cleanup: cleanup)
    }

    private func handleDropError(_ message: String) {
        Task { @MainActor in
            documentViewModel.errorMessage = message
        }
    }

    private var compactBottomBar: some View {
        HStack(spacing: 12) {
            importButton

            Menu {
                Button {
                    documentViewModel.reset()
                } label: {
                    Label("New Document", systemImage: "arrow.clockwise")
                }

                Button {
                    if isCompactLayout {
                        shouldPresentEntitiesAfterExtraction = true
                    }
                    Task {
                        await documentViewModel.extractEntities(language: appState.settings.preferredLanguage)
                    }
                } label: {
                    Label(documentViewModel.isExtractingEntities ? "Extracting..." : "Extract Entities", systemImage: "target")
                }
                .disabled(documentViewModel.isExtractingEntities)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .frame(minWidth: 48)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
            }
            .frame(maxWidth: 120)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(radius: 3, y: 2)
        .padding(.horizontal)
    }

    private func defaultExportFilename(for filename: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return base.isEmpty ? "redacted" : "\(base)-redacted"
    }
}

private struct EntitySelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: DocumentViewModel
    let onRedact: () -> Void

    private var hasEntities: Bool {
        viewModel.recognizedEntities.values.contains { !$0.isEmpty }
    }

    private var hasSelection: Bool {
        !viewModel.selectedEntities.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if hasEntities {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(RecognizedEntity.Label.allCases, id: \.self) { label in
                                let entities = viewModel.recognizedEntities[label] ?? []
                                if !entities.isEmpty {
                                    EntityChipGroup(label: label, entities: entities, selection: viewModel)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No entities detected yet. Try extracting again.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                if hasSelection {
                    Button("Redact Selected") {
                        onRedact()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .navigationTitle("Detected Entities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct EntityChipGroup: View {
    let label: RecognizedEntity.Label
    let entities: [RecognizedEntity]
    @ObservedObject var selection: DocumentViewModel

    private var color: Color {
        switch label {
        case .person: return .red
        case .organization: return .blue
        case .location: return .green
        case .custom: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(label.rawValue)
                .font(.caption)
                .foregroundColor(color)
            HStack {
                ForEach(entities) { entity in
                    let isSelected = selection.selectedEntities.contains(entity)
                    Text(entity.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? color.opacity(0.2) : Color.gray.opacity(0.1))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isSelected ? color : Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .onTapGesture {
                            selection.toggleSelection(for: entity)
                        }
                }
            }
        }
    }
}

extension Notification.Name {
    static let documentRequestSummary = Notification.Name("DocumentRequestSummary")
}
