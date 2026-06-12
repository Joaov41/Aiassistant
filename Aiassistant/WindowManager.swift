import SwiftUI
import AppKit

// Consolidated WindowManager to handle all window types it's aware of
// It acts as the delegate for the windows it manages to handle cleanup.
class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    // Use NSMapTable for weak references to windows and their associated views
    // Weak-to-weak helps prevent retain cycles with the views
    private var onboardingWindows = NSMapTable<NSWindow, NSHostingView<OnboardingView>>.weakToWeakObjects()
    private var settingsWindows = NSMapTable<NSWindow, NSHostingView<SettingsView>>.weakToWeakObjects()
    private var popupWindows = NSMapTable<PopupWindow, NSHostingView<PopupView>>.weakToWeakObjects()
    private var quickActionsWindows = NSMapTable<QuickActionsWindow, NSHostingView<QuickActionsView>>.weakToWeakObjects() // For triple-tap
    // Use NSHashTable for weak references to ResponseWindows (no associated view needed here)
    private var responseWindows = NSHashTable<ResponseWindow>.weakObjects()

    private override init() {
        super.init()
        print("WindowManager initialized.")
    }

    // --- ADDED: Public accessor to check for active response windows ---
    var hasActiveResponseWindows: Bool {
        // Check if the weak-referenced collection contains any objects
        return !responseWindows.allObjects.isEmpty
    }
    // --- END ADDED ---

    // Helper to ensure UI updates are on the main thread
    private func performOnMainThread(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.async(execute: operation)
        }
    }

    // MARK: - Window Registration Methods

    func addOnboardingWindow(_ window: NSWindow, hostingView: NSHostingView<OnboardingView>) {
         performOnMainThread { [weak self] in
             guard let self = self else { return }
             // Ensure window is not already tracked to avoid issues
             guard self.onboardingWindows.object(forKey: window) == nil else {
                 print("Warning: Onboarding window already registered.")
                 return
             }
             self.onboardingWindows.setObject(hostingView, forKey: window)
             window.delegate = self // Set WindowManager as delegate
             window.level = .floating
             window.center()
             print("Onboarding window registered.")
         }
    }

    func addSettingsWindow(_ window: NSWindow, hostingView: NSHostingView<SettingsView>) {
        performOnMainThread { [weak self] in
            guard let self = self else { return }
             guard self.settingsWindows.object(forKey: window) == nil else {
                 print("Warning: Settings window already registered.")
                 // Optionally bring existing to front?
                 // window.makeKeyAndOrderFront(nil)
                 return
             }
            self.settingsWindows.setObject(hostingView, forKey: window)
            window.delegate = self // Set WindowManager as delegate
            print("Settings window registered.")
        }
    }

    func closeSettingsWindow(appState: AppState, showOnlyApiSetup: Bool) {
        performOnMainThread { [weak self] in
            guard let self = self else { return }
            let windows = (self.settingsWindows.keyEnumerator().allObjects as? [NSWindow]) ?? []
            guard let window = windows.first(where: { window in
                guard let hostingView = self.settingsWindows.object(forKey: window) else { return false }
                return hostingView.rootView.appState === appState
                    && hostingView.rootView.showOnlyApiSetup == showOnlyApiSetup
            }) else {
                print("Could not find tracked settings window to close.")
                return
            }

            window.orderOut(nil)
        }
    }

    func addPopupWindow(_ window: PopupWindow) {
        performOnMainThread { [weak self] in
            guard let self = self, let view = window.contentView as? NSHostingView<PopupView> else {
                print("Error: Could not get hosting view for Popup window.")
                return
            }
             guard self.popupWindows.object(forKey: window) == nil else {
                 print("Warning: Popup window already registered.")
                 // Optionally bring existing to front?
                 // window.makeKeyAndOrderFront(nil)
                 return
             }
            self.popupWindows.setObject(view, forKey: window)
            window.delegate = self // Set WindowManager as delegate
            print("Popup window registered.")
        }
    }

    func addQuickActionsWindow(_ window: QuickActionsWindow) {
        performOnMainThread { [weak self] in
            // Ensure QuickActionsWindow and QuickActionsView exist
            guard let self = self, let view = window.contentView as? NSHostingView<QuickActionsView> else {
                 print("Error: Could not get hosting view for Quick Actions window.")
                 return
            }
             guard self.quickActionsWindows.object(forKey: window) == nil else {
                 print("Warning: Quick Actions window already registered.")
                 // Optionally bring existing to front?
                 // window.makeKeyAndOrderFront(nil)
                 return
             }
            self.quickActionsWindows.setObject(view, forKey: window)
            window.delegate = self // Set WindowManager as delegate
            print("Quick Actions window registered.")
        }
    }

    func addResponseWindow(_ window: ResponseWindow) {
        performOnMainThread { [weak self] in
            guard let self = self else { return }
            // NSHashTable checks for containment
            if !self.responseWindows.contains(window) {
                self.responseWindows.add(window)
                window.delegate = self // Set WindowManager as delegate
                print("Response window registered.")
                window.makeKeyAndOrderFront(nil) // Show it immediately
            } else {
                 print("Warning: Response window already registered.")
            }
        }
    }

    // MARK: - Window Removal / Cleanup Methods (Called Internally via Delegate)

    // These are kept private as they should only be called by windowWillClose
    private func removeOnboardingWindow(_ window: NSWindow) {
        performOnMainThread { [weak self] in
            if self?.onboardingWindows.object(forKey: window) != nil {
                self?.onboardingWindows.removeObject(forKey: window)
                print("Onboarding window removed by WM.")
            }
        }
    }

     private func removeSettingsWindow(_ window: NSWindow) {
        performOnMainThread { [weak self] in
            if self?.settingsWindows.object(forKey: window) != nil {
                self?.settingsWindows.removeObject(forKey: window)
                print("Settings window removed by WM.")
            }
        }
    }

    // Cleanup methods call the window's specific cleanup if it exists
    private func cleanupPopupWindow(_ window: PopupWindow) {
        performOnMainThread { [weak self, weak window] in
            guard let self = self, let window = window else { 
                print("Window or WindowManager was deallocated during cleanup")
                return 
            }
            
            if self.popupWindows.object(forKey: window) != nil {
                print("Starting removal of Popup window from WindowManager")
                
                // First remove from tracking collection
                self.popupWindows.removeObject(forKey: window)
                
                // Then call cleanup on the window
                window.cleanup()
                
                print("Popup window fully removed from WindowManager")
            } else {
                print("Popup window was not found in tracking collection")
            }
        }
    }

    private func cleanupQuickActionsWindow(_ window: QuickActionsWindow) {
        performOnMainThread { [weak self, weak window] in
            guard let self = self, let window = window else { 
                print("Window or WindowManager was deallocated during cleanup")
                return 
            }
            
            if self.quickActionsWindows.object(forKey: window) != nil {
                print("Starting removal of Quick Actions window from WindowManager")
                
                // First remove from tracking collection
                self.quickActionsWindows.removeObject(forKey: window)
                
                // Then call cleanup on the window
                window.cleanup()
                
                print("Quick Actions window fully removed from WindowManager")
            } else {
                print("Quick Actions window was not found in tracking collection")
            }
        }
    }

    // This is PRIVATE - only WindowManager calls this via its delegate method
    private func removeResponseWindow(_ window: ResponseWindow) {
        if self.responseWindows.contains(window) {
            print("🔽 Removing ResponseWindow from tracking collection first")
            
            // First remove from tracking collection
            self.responseWindows.remove(window)
            
            // Create a strong, local reference to help avoid premature deallocation
            let windowRef = window
            
            print("🔽 WindowManager calling cleanup() on ResponseWindow")
            
            // Call cleanup directly without delay
            windowRef.cleanup()
            
            // Perform extra validation
            if self.responseWindows.contains(windowRef) {
                print("⚠️ WARNING: Window still in collection after removal attempt!")
                self.responseWindows.remove(windowRef)
            }
            
            print("🔽 ResponseWindow removal completed")
        } else {
            print("⚠️ Response window was not found in tracking collection")
        }
    }


    // MARK: - Transitions

    func transitonFromOnboardingToSettings(appState: AppState) {
        performOnMainThread { [weak self] in
            guard let self = self else { return }
            guard let currentOnboardingWindow = self.onboardingWindows.keyEnumerator().nextObject() as? NSWindow else {
                 print("Error: Could not find onboarding window for transition.")
                 return
            }

            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            settingsWindow.title = "Complete Setup"; settingsWindow.center()
            settingsWindow.isReleasedWhenClosed = true // Let ARC handle cleanup via delegate

            // Ensure SettingsView exists
            let settingsView = SettingsView(appState: appState, showOnlyApiSetup: true)
            let hostingView = NSHostingView(rootView: settingsView)
            settingsWindow.contentView = hostingView

            self.addSettingsWindow(settingsWindow, hostingView: hostingView) // WM handles delegate
            settingsWindow.makeKeyAndOrderFront(nil)
            currentOnboardingWindow.close() // WM delegate will remove onboarding window
            print("Transitioned from Onboarding to Settings.")
        }
    }

    // MARK: - Global Cleanup

    func cleanupAllWindows() {
        performOnMainThread { [weak self] in
             guard let self = self else { return }
             print("Cleaning up all managed windows...")

             // Create arrays from enumerators/allObjects before iterating for closing
             let onboarding = (self.onboardingWindows.keyEnumerator().allObjects as? [NSWindow]) ?? []
             let settings = (self.settingsWindows.keyEnumerator().allObjects as? [NSWindow]) ?? []
             let popups = (self.popupWindows.keyEnumerator().allObjects as? [PopupWindow]) ?? []
             let quickActions = (self.quickActionsWindows.keyEnumerator().allObjects as? [QuickActionsWindow]) ?? []
             let responses = self.responseWindows.allObjects

             let allWindows: [NSWindow] = onboarding + settings + popups + quickActions + responses // Combine all types

             allWindows.forEach {
                 $0.delegate = nil // Prevent delegate calls during forced close
                 $0.close()
             }
             // Clear the collections after closing all windows
             self.clearAllWindows()
        }
    }

    private func clearAllWindows() {
        // Called on main thread by cleanupAllWindows
        onboardingWindows.removeAllObjects()
        settingsWindows.removeAllObjects()
        popupWindows.removeAllObjects()
        quickActionsWindows.removeAllObjects()
        responseWindows.removeAllObjects()
        print("All window references cleared.")
    }

    // MARK: - NSWindowDelegate Methods

    // This single delegate method handles closing for ALL window types managed here.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        print("🚪 WindowManager.windowWillClose - \(window.title ?? "Untitled")")

        // Determine window type and call appropriate cleanup/removal method
        // Ensure this runs on the main thread for safety with collections
        if let response = window as? ResponseWindow {
            // Special handling for ResponseWindow which seems to have more issues
            print("🚪 ResponseWindow detected in windowWillClose - handling specially")
            self.removeResponseWindow(response)
        } else {
            performOnMainThread { [weak self] in
                 guard let self = self else { return }

                 if let popup = window as? PopupWindow {
                     self.cleanupPopupWindow(popup) // Calls cleanup and removes
                 } else if let quickActions = window as? QuickActionsWindow {
                     self.cleanupQuickActionsWindow(quickActions) // Calls cleanup and removes
                 } else if self.onboardingWindows.object(forKey: window) != nil {
                     self.removeOnboardingWindow(window) // Just removes reference
                 } else if self.settingsWindows.object(forKey: window) != nil {
                     self.removeSettingsWindow(window) // Just removes reference
                 } else {
                     print("🚪 Closing window not actively managed or already removed: \(window.title ?? "Unknown")")
                 }
            }
        }
    }

     func windowDidBecomeKey(_ notification: Notification) {
         guard let window = notification.object as? NSWindow else { return }
         // Ensure popups stay floating
         if window is PopupWindow || window is QuickActionsWindow {
             performOnMainThread {
                  window.level = .floating
             }
         }
     }
}

// NOTE: The problematic extension for NSMapTable has been removed.
