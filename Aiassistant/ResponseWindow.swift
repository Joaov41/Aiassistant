import SwiftUI // Correct: NOT importimport or SwiftUl
import AppKit  // Correct: Ensure this line exists

// Ensure this class is defined ONLY ONCE, in this file (ResponseWindow.swift).
// Ensure the definition was DELETED from ResponseView.swift.
class ResponseWindow: NSWindow {
    // Use a strong reference to prevent premature deallocation
    var hostingController: NSHostingController<ResponseView>?
    
    // Track if cleanup has been performed to avoid double cleanup
    private var cleanupPerformed = false
    
    // Add a delegate reference tracker to help with debugging
    private weak var delegateTracker: NSWindowDelegate?
    
    deinit {
        print("🔒 ResponseWindow deinit called")
        if !cleanupPerformed {
            print("🔒 WARNING: ResponseWindow deinit called before cleanup - performing emergency cleanup")
            cleanup()
        }
    }

    // Create custom initializer for this window type
    init(with responseView: ResponseView, title: String = "Assistant", size: NSSize? = nil, hasImages: Bool = false) {
        // Adjust default size for windows containing images
        let windowSize = size ?? NSSize(width: hasImages ? 600 : 500, height: hasImages ? 600 : 400)
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        self.title = title
        self.titlebarAppearsTransparent = true
        self.isReleasedWhenClosed = false // IMPORTANT: We will handle release manually
        
        // Configure window appearance for dark mode compatibility
        self.appearance = NSAppearance(named: .darkAqua)
        self.titleVisibility = .visible
        // Add grayish background tint (slightly darker than other windows since it already had 0.5 alpha)
        self.backgroundColor = NSColor.gray.withAlphaComponent(0.45)
        
        // Make windows always appear on top
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Create the hosting controller
        let hostingVC = NSHostingController(rootView: responseView)
        self.hostingController = hostingVC
        
        // Use the hosting view as content
        let hostingView = hostingVC.view
        hostingView.frame = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView
        
        // Set minimum size
        self.minSize = NSSize(width: 350, height: 300)
        
        // Center on screen
        self.center()
    }
    
    // Override the close method to ensure we use WindowManager
    override func close() {
        if !cleanupPerformed {
            print("🔒 ResponseWindow close() called - notifying delegate to handle cleanup")
            // Let the delegate (WindowManager) handle the cleanup
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: self)
            super.close()
        } else {
            print("🔒 ResponseWindow close() called after cleanup - just closing")
            super.close()
        }
    }
    
    // Handle cleanup - called by WindowManager
    func cleanup() {
        if cleanupPerformed {
            print("🔒 ResponseWindow cleanup already performed - skipping")
            return
        }
        
        print("🔒 ResponseWindow cleanup - START")
        cleanupPerformed = true
        
        // First clear the content view reference
        if let contentView = self.contentView {
            let subviews = contentView.subviews
            for subview in subviews {
                subview.removeFromSuperview()
            }
        }
        self.contentView = nil
        
        // Then release the hosting controller
        if hostingController != nil {
            print("🔒 Releasing hosting controller")
            hostingController = nil
        }
        
        print("🔒 ResponseWindow cleanup - COMPLETE")
    }

    // Required initializers for NSWindow subclass
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Allow window to become key/main for interaction
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

