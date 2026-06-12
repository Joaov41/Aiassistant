import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            Text("AI Assistant (macOS)")
                .font(.title)
            
            // Button to trigger processing a URL from the clipboard.
            Button("Process URL from Clipboard") {
                appState.processURLFromClipboard()
            }
            .padding()
            
            if appState.isProcessing {
                ProgressView("Processing...")
            }
            
            // Display the extracted text (if any)
            if !appState.selectedText.isEmpty {
                ScrollView {
                    Text(appState.selectedText)
                        .padding()
                }
                .frame(maxWidth: 600, maxHeight: 300)
                .border(Color.gray)
            } else {
                Text("No text extracted yet.")
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }
}


