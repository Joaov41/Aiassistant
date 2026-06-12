import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox
import Combine // Import Combine for timer

// Ensure WindowManager, PopupWindow, QuickActionsWindow, SettingsView, AppState etc. are defined correctly in other files.
// Ensure AccessibilityHelper is defined correctly.

class AppDelegate: NSObject, NSApplicationDelegate { // No NSWindowDelegate needed here
    private static var sharedStatusItem: NSStatusItem?

    // Keep track if the user triggered the app from a service
    private var isServiceTriggered = false

    // The single status bar item (pencil icon)
    var statusBarItem: NSStatusItem! {
        get {
            if AppDelegate.sharedStatusItem == nil {
                AppDelegate.sharedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                configureStatusBarItem()
            }
            return AppDelegate.sharedStatusItem
        }
        set {
            AppDelegate.sharedStatusItem = newValue
        }
    }

    // Your shared app state
    let appState = AppState.shared

    // Windows - Keep local references for direct access when needed
    private weak var settingsWindow: NSWindow?
    private(set) weak var popupWindow: PopupWindow?
    private(set) weak var quickActionsWindow: QuickActionsWindow? // Reference for the quick actions window

    // --- Tap Detection State ---
    private enum TapState {
        case idle
        case firstPress(time: Date)
        case secondPress(time: Date)
    }
    private var currentTapState: TapState = .idle
    private let tapInterval: TimeInterval = 0.35 // Max interval between taps (350ms)
    private var tapTimer: Timer? // Timer to handle timeouts

    // Event monitors for keyboard events. Global handles other apps; local handles Aiassistant while it is frontmost.
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.servicesProvider = self
        setupMenuBar()
        setupShiftTapMonitor() // Sets up the tap detection
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        tapTimer?.invalidate()
        WindowManager.shared.cleanupAllWindows() // Ask WindowManager to close all windows
    }

    // MARK: - Status Bar

    private func configureStatusBarItem() {
        guard let button = statusBarItem?.button else { return }
        button.image = NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "AI Assistant")
    }

    private func setupMenuBar() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Clear Clipboard", action: #selector(clearClipboardFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator()) // Separator
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Reset App", action: #selector(resetApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusBarItem.menu = menu
    }

    // MARK: - Show / Toggle Popups

    // --- Action Triggers ---
    private func triggerDoubleTapAction() {
        print("ACTION: Double-Tap Triggered")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.toggleMainPopup()
        }
    }

    private func triggerTripleTapAction() {
        print("ACTION: Triple-Tap Triggered")
        DispatchQueue.main.async { [weak self] in
            // Ensure QuickActionsWindow exists before calling show
            self?.showQuickActionsPopup()
        }
    }

    // --- Main Popup Window ---
    private func toggleMainPopup() {
        if let window = self.popupWindow {
             print("Toggle: Closing existing Popup Window.")
             closePopupWindow()
        } else {
             print("Toggle: No existing Popup Window found.")
            // Close quick actions if open before showing main popup
            if quickActionsWindow != nil {
                 print("Toggle: Closing Quick Actions window first.")
                 closeQuickActionsWindow()
            }
            showPopupWindow()
        }
    }

    // ** CHANGED: Made internal (default access) **
    func showPopupWindow() {
        guard self.popupWindow == nil else {
             print("Show Popup: Window reference already exists, bringing to front.")
             self.popupWindow?.makeKeyAndOrderFront(nil)
             return
        }
        print("Showing Main Popup Window")
        appState.activeProvider.cancel()

        let shouldCapture = appState.hasInitializedCapture
        appState.hasInitializedCapture = true
        
        if shouldCapture,
           let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            appState.previousApplication = frontApp
            appState.captureExternalSelection()
        } else {
             appState.previousApplication = nil
             appState.selectedText = ""
             appState.selectedImages = []
             appState.selectedVideos = []
             appState.lastClipboardType = .none
             print("Own app is frontmost, clearing selection context.")
        }

        // Ensure PopupWindow class exists
        let window = PopupWindow(appState: appState)
        self.popupWindow = window
        WindowManager.shared.addPopupWindow(window) // Register with Manager

        window.setContentSize(NSSize(width: 400, height: 500))
        window.positionNearMouse()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        appState.isPopupVisible = true
    }

    // ** CHANGED: Made internal (default access) **
    func closePopupWindow() {
        if let windowToClose = self.popupWindow {
             print("Requesting Popup Window close.")
             windowToClose.close() // Ask window to close; WM delegate handles cleanup
        } else {
             print("Close Popup: No window reference to close.")
        }
         appState.isPopupVisible = false // Update state here as well
    }

    // --- Quick Actions Popup ---
    // ** CHANGED: Made internal (default access) **
    func showQuickActionsPopup() {
        // Ensure QuickActionsWindow class exists before calling this
        guard self.quickActionsWindow == nil else {
            print("Show Quick Actions: Window reference already exists, bringing to front.")
            self.quickActionsWindow?.makeKeyAndOrderFront(nil)
            return
        }
        print("Showing Quick Actions Window")

        if popupWindow != nil {
            closePopupWindow() // Close main popup first
        }

        appState.activeProvider.cancel()
        let shouldCaptureQuickActions = true
        appState.hasInitializedCapture = true
        
         if shouldCaptureQuickActions,
            let frontApp = NSWorkspace.shared.frontmostApplication,
            frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            appState.previousApplication = frontApp
            appState.captureExternalSelection()
         } else {
             appState.previousApplication = nil
             appState.selectedText = ""
             appState.selectedImages = []
             appState.selectedVideos = []
             appState.lastClipboardType = .none
             print("Own app is frontmost, clearing selection context.")
         }

        // Ensure QuickActionsWindow class exists
        let window = QuickActionsWindow(appState: appState, inlineReplacementMode: true)
        self.quickActionsWindow = window // Update local reference
        WindowManager.shared.addQuickActionsWindow(window) // Register

        window.setContentSize(NSSize(width: 350, height: 250))
        window.positionNearMouse()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // ** CHANGED: Made internal (default access) **
    func closeQuickActionsWindow() {
        if let windowToClose = self.quickActionsWindow {
             print("Requesting Quick Actions Window close.")
             windowToClose.close() // Ask window to close; WM delegate handles cleanup
        } else {
             print("Close Quick Actions: No window reference to close.")
        }
    }


    // MARK: - Settings

    @objc private func showSettings() {
        // Rely on local weak ref first
        if let existingWindow = self.settingsWindow {
             print("Settings window already exists. Activating.")
             existingWindow.makeKeyAndOrderFront(nil)
             NSApp.activate(ignoringOtherApps: true)
             return
        }

        print("Creating new Settings window.")
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        newWindow.title = "Settings"
        newWindow.center()
        newWindow.isReleasedWhenClosed = true // Let WM delegate handle cleanup
        
        // Enable translucency
        newWindow.titlebarAppearsTransparent = true
        newWindow.backgroundColor = NSColor.clear
        newWindow.isOpaque = false
        newWindow.hasShadow = true

        // Ensure SettingsView is defined
        let settingsView = SettingsView(appState: appState, showOnlyApiSetup: false)
        let hostingView = NSHostingView(rootView: settingsView)
        newWindow.contentView = hostingView
        newWindow.level = .normal

        self.settingsWindow = newWindow // Store local weak reference
        // Register with WindowManager which sets the delegate
        WindowManager.shared.addSettingsWindow(newWindow, hostingView: hostingView)

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func clearClipboardFromMenu() {
        print("Menu Action: Clear Clipboard triggered.")
        appState.clearClipboardData()
    }

    // MARK: - Reset

    @objc private func resetApp() {
        AppSettings.shared.resetAll()
        recreateStatusBarItem(); setupMenuBar()
        let alert = NSAlert(); alert.messageText = "App Reset Complete"
        alert.informativeText = "The app has been reset. Please restart if necessary."
        alert.alertStyle = .informational; alert.addButton(withTitle: "OK"); alert.runModal()
    }

    private func recreateStatusBarItem() {
        AppDelegate.sharedStatusItem = nil; _ = self.statusBarItem
    }

    // MARK: - Window Delegate REMOVED from AppDelegate

    // MARK: - Shift Tap Monitor (State Machine Logic)

    private func setupShiftTapMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleShiftEvent(event)
            return event
        }

         // Ensure AccessibilityHelper is defined and working for events in other apps
         guard AccessibilityHelper.checkAccessibilityPermissions() else {
             print("Accessibility permissions not granted. Global shift tap monitor not set up.")
	             DispatchQueue.main.async {
                 let alert = NSAlert()
                 alert.messageText = "Accessibility Access Required"
                 alert.informativeText = "AI Assistant needs Accessibility permissions to detect keyboard shortcuts. Please grant access in System Settings > Privacy & Security > Accessibility."
                 alert.addButton(withTitle: "Open Settings")
                 alert.addButton(withTitle: "Cancel")
                 let response = alert.runModal()
                 if response == .alertFirstButtonReturn {
                     NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                 }
	             }
	             return
	         }
	
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleShiftEvent(event)
        }
        print("Shift tap monitor set up.")
    }

    private func handleShiftEvent(_ event: NSEvent) {
        let shiftPressed = event.modifierFlags.contains(.shift)
        let isLeftShiftEvent = event.keyCode == 56 // Left Shift physical keycode

        if isLeftShiftEvent && shiftPressed {
            handleShiftPress()
        }
    }

    private func handleShiftPress() {
        let now = Date()
        tapTimer?.invalidate()

        switch currentTapState {
        case .idle:
            currentTapState = .firstPress(time: now)
            print("State: idle -> firstPress")
            tapTimer = Timer.scheduledTimer(withTimeInterval: tapInterval, repeats: false) { [weak self] _ in
                 print("State: firstPress timed out -> idle")
                 self?.currentTapState = .idle
            }

        case .firstPress(let t1):
            if now.timeIntervalSince(t1) < tapInterval {
                currentTapState = .secondPress(time: now)
                print("State: firstPress -> secondPress")
                tapTimer = Timer.scheduledTimer(withTimeInterval: tapInterval, repeats: false) { [weak self] _ in
                    print("State: secondPress timed out -> idle (Double Tap Action)")
                    self?.currentTapState = .idle
                    self?.triggerDoubleTapAction() // Double Tap Action
                }
            } else {
                currentTapState = .firstPress(time: now) // Reset
                print("State: firstPress (late) -> firstPress")
                 tapTimer = Timer.scheduledTimer(withTimeInterval: tapInterval, repeats: false) { [weak self] _ in
                      print("State: firstPress timed out -> idle")
                      self?.currentTapState = .idle
                 }
            }

        case .secondPress(let t2):
            if now.timeIntervalSince(t2) < tapInterval {
                print("State: secondPress -> idle (Triple Tap Action)") // Log correct action
                currentTapState = .idle // Reset
                triggerTripleTapAction() // *** THIS IS NOW UNCOMMENTED ***
            } else {
                currentTapState = .firstPress(time: now) // Reset
                print("State: secondPress (late) -> firstPress")
                 tapTimer = Timer.scheduledTimer(withTimeInterval: tapInterval, repeats: false) { [weak self] _ in
                      print("State: firstPress timed out -> idle")
                      self?.currentTapState = .idle
                 }
            }
        }
    }

    deinit {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        tapTimer?.invalidate()
        print("AppDelegate deinit.")
    }
}
