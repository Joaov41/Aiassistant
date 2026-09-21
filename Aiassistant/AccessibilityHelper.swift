import Cocoa
import ApplicationServices

struct TextReplacementTarget {
    let application: NSRunningApplication
    fileprivate let element: AXUIElement?
    fileprivate let fingerprint: TextSelectionFingerprint?
}

struct TextSelectionFingerprint: Equatable {
    let selectedText: String
    let rangeLocation: Int?
    let rangeLength: Int?
    let elementValue: String?

    init(selectedText: String, selectedRange: CFRange?, elementValue: String?) {
        self.selectedText = selectedText
        self.rangeLocation = selectedRange?.location
        self.rangeLength = selectedRange?.length
        self.elementValue = elementValue
    }
}

enum TextReplacementError: LocalizedError {
    case permissionDenied
    case targetUnavailable
    case selectionUnavailable
    case selectionChanged
    case replacementUnsupported
    case replacementFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Accessibility permission is required for inline replacement."
        case .targetUnavailable: return "The original application or window is no longer available."
        case .selectionUnavailable: return "The original text selection could not be verified."
        case .selectionChanged: return "The original text selection changed, so the result was not pasted."
        case .replacementUnsupported: return "This app does not permit safe replacement of the selected text."
        case .replacementFailed(let message): return "The selected text could not be replaced: \(message)"
        }
    }
}

@MainActor
enum AccessibilityHelper {
    static func checkAccessibilityPermissions(prompt: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func copyTextFromFocusedElement(targetApplication: NSRunningApplication? = nil) async -> String? {
        guard checkAccessibilityPermissions() else { return nil }
        guard let app = targetApplication ?? NSWorkspace.shared.frontmostApplication, !app.isTerminated else {
            return nil
        }

        if !app.isActive {
            app.activate(options: .activateIgnoringOtherApps)
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled else { return nil }

        let pasteboard = NSPasteboard.general
        let originalItems = snapshotPasteboardItems(from: pasteboard)
        pasteboard.clearContents()
        let preparedChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            restorePasteboardItems(originalItems, to: pasteboard)
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(app.processIdentifier)
        keyUp.postToPid(app.processIdentifier)

        let attempts = isSpreadsheetApplication(app) ? 15 : 10
        let delay = isSpreadsheetApplication(app) ? Duration.milliseconds(250) : .milliseconds(150)
        var copiedText: String?
        for _ in 0..<attempts {
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: delay)
            if pasteboard.changeCount != preparedChangeCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                copiedText = text
                break
            }
        }

        // Restore only if the clipboard still contains the synthetic copy result.
        if pasteboard.string(forType: .string) == copiedText {
            restorePasteboardItems(originalItems, to: pasteboard)
        }
        return copiedText
    }

    static func captureReplacementTarget(
        expectedText: String,
        targetApplication: NSRunningApplication
    ) throws -> TextReplacementTarget {
        guard checkAccessibilityPermissions() else { throw TextReplacementError.permissionDenied }
        guard !targetApplication.isTerminated else { throw TextReplacementError.targetUnavailable }
        let appElement = AXUIElementCreateApplication(targetApplication.processIdentifier)
        let element = elementAttribute(appElement, kAXFocusedUIElementAttribute)
        // Web-rendered editors (e.g. Outlook) often report a selection that does not
        // match the copied text, or no focused element at all. Only pin a fingerprint
        // when AX gives us one that provably matches; otherwise rely on the paste path.
        let fingerprint = element.map(selectionFingerprint(for:))
        let verified = fingerprint?.selectedText == expectedText ? fingerprint : nil
        return TextReplacementTarget(application: targetApplication, element: element, fingerprint: verified)
    }

    static func replaceTextInCapturedTarget(
        with newText: String,
        target: TextReplacementTarget
    ) async throws {
        guard checkAccessibilityPermissions() else { throw TextReplacementError.permissionDenied }
        let app = target.application
        guard !app.isTerminated else { throw TextReplacementError.targetUnavailable }

        if !app.isActive {
            app.activate(options: .activateIgnoringOtherApps)
            try? await Task.sleep(for: .milliseconds(300))
        }
        try Task.checkCancellation()

        // If we captured a verifiable selection, make sure the user hasn't moved it
        // (or focused a different field) before overwriting anything.
        if let targetElement = target.element, let fingerprint = target.fingerprint {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let currentElement = elementAttribute(appElement, kAXFocusedUIElementAttribute),
                  CFEqual(currentElement, targetElement),
                  selectionFingerprint(for: currentElement).selectedText == fingerprint.selectedText else {
                throw TextReplacementError.selectionChanged
            }
        }
        try await pasteOverSelection(newText, in: app)
    }

    /// Replace the live selection by placing `text` on the clipboard and simulating ⌘V
    /// through the HID event tap, exactly like the copy step does. This works uniformly
    /// across native and web-based editors, where AXSelectedText writes are unreliable.
    private static func pasteOverSelection(_ text: String, in app: NSRunningApplication) async throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            throw TextReplacementError.replacementFailed("Could not synthesize paste keystroke.")
        }
        let pasteboard = NSPasteboard.general
        let originalItems = snapshotPasteboardItems(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard pasteboard.string(forType: .string) == text else {
            restorePasteboardItems(originalItems, to: pasteboard)
            throw TextReplacementError.replacementFailed("Could not place the result on the clipboard.")
        }

        let keyDelay: Duration = isSpreadsheetApplication(app) ? .milliseconds(300) : .milliseconds(200)
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: keyDelay)
        }

        try? await Task.sleep(for: isSpreadsheetApplication(app) ? .milliseconds(500) : .milliseconds(300))
        if pasteboard.string(forType: .string) == text {
            restorePasteboardItems(originalItems, to: pasteboard)
        }
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard
              AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func selectionFingerprint(for element: AXUIElement) -> TextSelectionFingerprint {
        TextSelectionFingerprint(
            selectedText: stringAttribute(element, kAXSelectedTextAttribute) ?? "",
            selectedRange: rangeAttribute(element, kAXSelectedTextRangeAttribute),
            elementValue: stringAttribute(element, kAXValueAttribute)
        )
    }

    private static func isSpreadsheetApplication(_ app: NSRunningApplication) -> Bool {
        let identifier = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return identifier.contains("excel") || identifier.contains("numbers") || identifier.contains("sheets")
            || name.contains("excel") || name.contains("numbers") || name.contains("sheets")
    }

    private static func snapshotPasteboardItems(from pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private static func restorePasteboardItems(
        _ items: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
