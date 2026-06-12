import SwiftUI

// New NSWindow subclass specifically for the Quick Actions popup
class QuickActionsWindow: NSWindow {
    private var hostingController: NSHostingController<QuickActionsView>?
    private weak var appState: AppState?

    init(appState: AppState, inlineReplacementMode: Bool = false) {
        // Initial content rect, will be adjusted
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 250), // Default size
            styleMask: [.closable, .resizable, .miniaturizable, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )

        self.appState = appState

        // Create the SwiftUI view
        let quickActionsView = QuickActionsView(
            appState: appState,
            onComplete: { [weak self] in
             // Add a closure to close the window when an action completes or is cancelled
             // This ensures the window closes itself after an action.
             self?.close()
            },
            inlineReplacementMode: inlineReplacementMode
        )

        self.hostingController = NSHostingController(rootView: quickActionsView)
        self.contentView = hostingController?.view

        // Window styling
        self.isReleasedWhenClosed = false // Managed by WindowManager's delegate
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.level = .floating // Keep it above other windows
        // Add grayish background tint
        self.backgroundColor = NSColor.gray.withAlphaComponent(0.35)
        self.isOpaque = false

        // Set min/max sizes if needed
        self.minSize = NSSize(width: 300, height: 200)
        self.maxSize = NSSize(width: 600, height: 400) // Allow some resizing

        // Ensure content view resizes with window
        self.contentView?.autoresizingMask = [.width, .height]

        // Set initial size
        self.setContentSize(NSSize(width: 350, height: 250))
    }

    // Clean up the hosting controller when the window is no longer needed
    // This is called by WindowManager when the window is closing.
    func cleanup() {
        print("QuickActionsWindow cleanup started.")
        appState?.clearConversationContext()
        // Explicitly remove the content view first
        if let contentView = self.contentView {
            contentView.removeFromSuperview()
        }
        // Explicitly nil out references in a specific order
        contentView = nil
        hostingController = nil
        print("QuickActionsWindow cleanup completed.")
    }

    // Override close to ensure cleanup happens via WindowManager
    override func close() {
        // The actual removal and cleanup is handled by WindowManager calling cleanup()
        // via the delegate method (windowWillClose).
        // We just call super.close() to perform the standard closing procedure.
        print("QuickActionsWindow close() called.")
        super.close()
    }

    // Required initializers for NSWindow subclass
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Override canBecomeKey to allow interaction
     override var canBecomeKey: Bool {
         return true
     }

     // Override canBecomeMain to allow it to be the main window
     override var canBecomeMain: Bool {
         return true
     }
}
