import SwiftUI

@main
struct AiassistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .preferredColorScheme(.dark) // Forces dark mode for all SwiftUI views
                .frame(width: 0, height: 0)
                .hidden()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
} 