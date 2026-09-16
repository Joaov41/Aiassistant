import Cocoa
import ApplicationServices

struct TextReplacementTarget {
    let application: NSRunningApplication
    fileprivate let window: AXUIElement
    fileprivate let element: AXUIElement
    fileprivate let fingerprint: TextSelectionFingerprint
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
        guard let window = elementAttribute(appElement, kAXFocusedWindowAttribute),
              let element = elementAttribute(appElement, kAXFocusedUIElementAttribute) else {
            throw TextReplacementError.selectionUnavailable
        }
        let fingerprint = selectionFingerprint(for: element)
        guard fingerprint.selectedText == expectedText else { throw TextReplacementError.selectionUnavailable }
        return TextReplacementTarget(
            application: targetApplication,
            window: window,
            element: element,
            fingerprint: fingerprint
        )
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
            try? await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let currentWindow = elementAttribute(appElement, kAXFocusedWindowAttribute),
              CFEqual(currentWindow, target.window),
              let currentElement = elementAttribute(appElement, kAXFocusedUIElementAttribute),
              CFEqual(currentElement, target.element) else {
            throw TextReplacementError.selectionChanged
        }
        let currentFingerprint = selectionFingerprint(for: currentElement)
        guard currentFingerprint == target.fingerprint else {
            throw TextReplacementError.selectionChanged
        }

        var isSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            currentElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableStatus == .success, isSettable.boolValue else {
            throw TextReplacementError.replacementUnsupported
        }
        let status = AXUIElementSetAttributeValue(
            currentElement,
            kAXSelectedTextAttribute as CFString,
            newText as CFString
        )
        guard status == .success else {
            throw TextReplacementError.replacementFailed("Accessibility error \(status.rawValue).")
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
