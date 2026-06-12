import SwiftUI

@main
struct EmailRedactorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.documentViewModel)
                .environmentObject(appState.summaryViewModel)
                .environmentObject(appState.followUpViewModel)
                .environmentObject(appState.deanonymizerViewModel)
                .environmentObject(appState.settings)
                .preferredColorScheme(appState.settings.forceDarkMode ? .dark : nil)
        }
    }
}
