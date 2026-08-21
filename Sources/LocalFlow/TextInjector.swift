import AppKit
import ApplicationServices

/// Places text at the cursor of whatever app has focus.
/// Primary path: Accessibility API (precise, no clipboard involvement).
/// Fallback path: clipboard + synthetic Cmd+V (works almost everywhere).
final class TextInjector {

    func insert(_ text: String, preferAccessibility: Bool) {
        if preferAccessibility, insertViaAccessibility(text) {
            return
        }
        insertViaPaste(text)
    }

    // MARK: - Accessibility path

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef else { return false }
        let element = focusedRef as! AXUIElement

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else { return false }

        // Setting the selected text inserts at the caret
        // (or replaces the current selection).
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    // MARK: - Clipboard + paste path

    private func insertViaPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKeystroke(keyCode: 9, flags: .maskCommand) // Cmd+V

        // Restore whatever the user had on the clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let savedString {
                pasteboard.clearContents()
                pasteboard.setString(savedString, forType: .string)
            }
        }
    }

    // MARK: - Command Mode selection capture

    /// Reads the currently selected text in the frontmost app.
    /// Tries the Accessibility API first, then falls back to Cmd+C.
    func copySelectedText() async -> String? {
        if let selection = selectionViaAccessibility(), !selection.isEmpty {
            return selection
        }
        return await selectionViaCopy()
    }

    private func selectionViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        ) == .success else { return nil }
        return selectedRef as? String
    }

    private func selectionViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let changeCountBefore = pasteboard.changeCount

        postKeystroke(keyCode: 8, flags: .maskCommand) // Cmd+C
        try? await Task.sleep(nanoseconds: 300_000_000)

        var selection: String?
        if pasteboard.changeCount != changeCountBefore {
            selection = pasteboard.string(forType: .string)
        }
        // Put the user's clipboard back.
        pasteboard.clearContents()
        if let savedString {
            pasteboard.setString(savedString, forType: .string)
        }
        return selection
    }

    // MARK: - Keystrokes

    func sendUndoKeystroke() {
        postKeystroke(keyCode: 6, flags: .maskCommand) // Cmd+Z
    }

    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
