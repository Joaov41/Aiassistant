import SwiftUI

class PopupWindow: NSWindow {
    private var hostingController: NSHostingController<PopupView>?
    private weak var appState: AppState?
    
    init(appState: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.closable, .resizable, .miniaturizable, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )
        
        self.appState = appState
        let popupView = PopupView(appState: appState)
        self.hostingController = NSHostingController(rootView: popupView)
        self.contentView = hostingController?.view
        self.isReleasedWhenClosed = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.level = .floating
        // Add grayish background tint
        self.backgroundColor = NSColor.gray.withAlphaComponent(0.35)
        self.isOpaque = false
        
        // Set minimum window size
        self.minSize = NSSize(width: 300, height: 400)
        
        // Allow the window to be resized to any size
        self.maxSize = NSSize(width: CGFloat.infinity, height: CGFloat.infinity)
        
        // Make sure content view is resizable
        self.contentView?.autoresizingMask = [.width, .height]
        
        // Set content size
        self.setContentSize(NSSize(width: 400, height: 500))
    }
    
    func cleanup() {
        print("PopupWindow cleanup started.")
        appState?.clearConversationContext()
        // Explicitly remove the content view first
        if let contentView = self.contentView {
            contentView.removeFromSuperview()
        }
        // Explicitly nil out references in a specific order
        contentView = nil
        hostingController = nil
        print("PopupWindow cleanup completed.")
    }
    
    // Override close to ensure cleanup happens via WindowManager
    override func close() {
        // The actual removal and cleanup is handled by WindowManager calling cleanup()
        // via the delegate method (windowWillClose).
        print("PopupWindow close() called.")
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

extension NSWindow {
    func positionNearMouse() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }

        if let screen = screen {
            contentView?.layoutSubtreeIfNeeded()
            let windowSize = self.frame.size
            let visibleFrame = screen.visibleFrame
            let margin: CGFloat = 12
            let unclampedOrigin = NSPoint(
                x: mouseLocation.x - windowSize.width / 2,
                y: mouseLocation.y - windowSize.height / 2
            )
            let origin = NSPoint(
                x: min(
                    max(unclampedOrigin.x, visibleFrame.minX + margin),
                    visibleFrame.maxX - windowSize.width - margin
                ),
                y: min(
                    max(unclampedOrigin.y, visibleFrame.minY + margin),
                    visibleFrame.maxY - windowSize.height - margin
                )
            )
            self.setFrameOrigin(origin)
        }
    }
}
