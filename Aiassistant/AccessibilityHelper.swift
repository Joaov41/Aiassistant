import Cocoa
import ApplicationServices

class AccessibilityHelper {
    
    /// Check if the app has proper accessibility permissions
    static func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        print("Accessibility permissions enabled: \(accessEnabled)")
        return accessEnabled
    }
    
    /// Simulate Cmd+C in the specified application (or current frontmost one) using HID system state, then read the pasteboard.
    static func copyTextFromFocusedElement(targetApplication: NSRunningApplication? = nil) -> String? {
        // First check accessibility permissions
        guard checkAccessibilityPermissions() else {
            print("Error: Accessibility permissions not granted")
            return nil
        }
        
        // Resolve the application we want to target
        guard let resolvedApp = targetApplication ?? NSWorkspace.shared.frontmostApplication else {
            print("Error: No target application found for copy operation")
            return nil
        }
        
        // Ensure the target app is active so the simulated key events go to the right place
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != resolvedApp.processIdentifier {
            resolvedApp.activate(options: .activateIgnoringOtherApps)
            Thread.sleep(forTimeInterval: 0.25)
        }
        
        // Check if this is a spreadsheet application
        let isSpreadsheetApp = resolvedApp.bundleIdentifier?.contains("excel") == true || 
                               resolvedApp.bundleIdentifier?.contains("numbers") == true || 
                               resolvedApp.bundleIdentifier?.contains("sheets") == true ||
                               resolvedApp.localizedName?.lowercased().contains("excel") == true ||
                               resolvedApp.localizedName?.lowercased().contains("numbers") == true ||
                               resolvedApp.localizedName?.lowercased().contains("sheets") == true
        
        print("Starting copy operation in \(resolvedApp.localizedName ?? "Unknown")...")
        print("Is spreadsheet app: \(isSpreadsheetApp)")
        
        // Store the current pasteboard contents
        let pasteboard = NSPasteboard.general
        let oldPasteboardItems = snapshotPasteboardItems(from: pasteboard)
        let oldPasteboardChangeCount = pasteboard.changeCount
        print("Initial pasteboard change count: \(oldPasteboardChangeCount)")
        
        // Clear the pasteboard to ensure we don't get stale data
        pasteboard.clearContents()
        Thread.sleep(forTimeInterval: 0.1)
        
        // Create event source targeting the application
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("Error creating CGEventSource for simulating copy.")
            restorePasteboardItems(oldPasteboardItems, to: pasteboard)
            return nil
        }
        
        // Ensure we're using the correct key codes
        let cmdKeyCode: CGKeyCode = 0x37  // Command key
        let cKeyCode: CGKeyCode = 0x08    // 'C' key
        
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true)
        let cDown   = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
        let cUp     = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
        
        // Set the Command flag on all events
        let commandFlag: CGEventFlags = [.maskCommand]
        cmdDown?.flags = commandFlag
        cDown?.flags = commandFlag
        cUp?.flags = commandFlag
        cmdUp?.flags = commandFlag
        
        // Post the events with longer delays for spreadsheet apps
        print("Sending copy key events to \(resolvedApp.localizedName ?? "Unknown")...")
        
        // Adjust timing for spreadsheet applications
        let keyDelay = isSpreadsheetApp ? 0.3 : 0.2
        
        // First attempt with appropriate delays
        cmdDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyDelay)
        cDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyDelay)
        cUp?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyDelay)
        cmdUp?.post(tap: .cghidEventTap)
        
        // Initial delay before checking pasteboard - longer for spreadsheets
        Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.5 : 0.3)
        
        // Wait for the pasteboard to be updated
        let maxAttempts = isSpreadsheetApp ? 15 : 10 // More attempts for spreadsheets
        var attempts = 0
        var copiedText: String?
        
        print("Waiting for pasteboard update...")
        while attempts < maxAttempts {
            let currentChangeCount = pasteboard.changeCount
            print("Attempt \(attempts + 1): Change count \(currentChangeCount)")
            
            if currentChangeCount != oldPasteboardChangeCount {
                if let text = pasteboard.string(forType: .string), !text.isEmpty {
                    print("Successfully copied text of length: \(text.count)")
                    copiedText = text
                    break
                }
            }
            
            // If we haven't succeeded after half the attempts, try sending the key events again
            if attempts == maxAttempts / 2 {
                print("Retrying copy operation...")
                cmdDown?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.4 : 0.3)
                cDown?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.4 : 0.3)
                cUp?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.4 : 0.3)
                cmdUp?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.4 : 0.3)
            }
            
            // Wait longer between attempts for spreadsheet apps
            Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.3 : 0.2)
            attempts += 1
        }
        
        // Restore original pasteboard content no matter the result
        restorePasteboardItems(oldPasteboardItems, to: pasteboard)
        
        return copiedText
    }
    
    /// Replace the external app's selected text by placing `newText` on the clipboard, reactivating the app,
    /// and simulating a Cmd+V keystroke using HID system state.
    static func replaceTextInFocusedElement(with newText: String, targetApplication: NSRunningApplication? = nil) {
        // Check accessibility permissions first
        guard checkAccessibilityPermissions() else {
            print("Error: Accessibility permissions not granted")
            return
        }
        
        // Get the target application
        let resolvedApp = targetApplication ?? AppState.shared.previousApplication
        
        guard let targetApp = resolvedApp else {
            print("Error: No target application found")
            return
        }
        
        // Check if this is a spreadsheet application 
        let isSpreadsheetApp = targetApp.bundleIdentifier?.contains("excel") == true || 
                               targetApp.bundleIdentifier?.contains("numbers") == true || 
                               targetApp.bundleIdentifier?.contains("sheets") == true ||
                               targetApp.localizedName?.lowercased().contains("excel") == true ||
                               targetApp.localizedName?.lowercased().contains("numbers") == true ||
                               targetApp.localizedName?.lowercased().contains("sheets") == true
        
        print("Starting paste operation in \(targetApp.localizedName ?? "Unknown")...")
        
        // Store current clipboard content
        let pasteboard = NSPasteboard.general
        let oldClipboardItems = snapshotPasteboardItems(from: pasteboard)
        
        // Place the new text on the clipboard
        pasteboard.clearContents()
        Thread.sleep(forTimeInterval: 0.1)
        pasteboard.setString(newText, forType: .string)
        
        // Verify the text was placed on the clipboard
        guard let verifyText = pasteboard.string(forType: .string),
              verifyText == newText else {
            print("Error: Failed to place new text on clipboard")
            return
        }
        
        // Ensure the target application is frontmost and active
        if !targetApp.isActive {
            targetApp.activate(options: .activateIgnoringOtherApps)
            // Give applications time to activate
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        // Create event source
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("Error: Failed to create CGEventSource for simulating paste.")
            return
        }
        
        // Create key events
        let cmdKeyCode: CGKeyCode = 0x37  // Command key
        let vKeyCode: CGKeyCode = 0x09    // 'V' key
        
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
        
        // Set the Command flag on all events
        let commandFlag: CGEventFlags = [.maskCommand]
        cmdDown?.flags = commandFlag
        vDown?.flags = commandFlag
        vUp?.flags = commandFlag
        cmdUp?.flags = commandFlag
        
        // Send the paste events - longer delays for spreadsheets
        print("Sending paste key events...")
        cmdDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.3 : 0.2)
        vDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.3 : 0.2)
        vUp?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: isSpreadsheetApp ? 0.3 : 0.2)
        cmdUp?.post(tap: .cghidEventTap)
        
        // For spreadsheet applications, provide more time to process the paste
        let waitTime = isSpreadsheetApp ? 0.5 : 0.3
        print("Waiting \(waitTime) seconds for paste operation to complete...")
        Thread.sleep(forTimeInterval: waitTime)
        
        // Restore the original clipboard content
        restorePasteboardItems(oldClipboardItems, to: pasteboard)
        print("Restored original clipboard content")
        
        print("Paste operation completed")
    }
}

extension AccessibilityHelper {
    /// Capture the existing pasteboard items so we can restore them after synthetic copy/paste operations.
    private static func snapshotPasteboardItems(from pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataMap[type] = data
                }
            }
            return dataMap
        }
    }
    
    /// Restore previously captured pasteboard items.
    private static func restorePasteboardItems(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems: [NSPasteboardItem] = items.map { dataMap in
            let item = NSPasteboardItem()
            for (type, data) in dataMap {
                item.setData(data, forType: type)
            }
            return item
        }
        
        pasteboard.writeObjects(restoredItems)
    }
}
