import AppKit
import ApplicationServices

/// Puts text at the user's cursor, preferring the Accessibility API so the clipboard is untouched.
enum Inserter {
    enum Outcome { case insertedAX, pastedViaClipboard, noTextField }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func insert(_ text: String) -> Outcome {
        guard let el = focusedEditableElement() else { return .noTextField }
        let before = stringAttr(el, kAXValueAttribute)
        let err = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if err == .success {
            // Some apps (Electron, web views) report success but do nothing; verify.
            let after = stringAttr(el, kAXValueAttribute)
            if before == nil && after == nil { pasteViaClipboard(text); return .pastedViaClipboard }
            if after != before { return .insertedAX }
        }
        pasteViaClipboard(text)
        return .pastedViaClipboard
    }

    private static func focusedEditableElement() -> AXUIElement? {
        if let app = NSWorkspace.shared.frontmostApplication {
            // Ask Electron/Chromium apps to expose their accessibility tree.
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let sys = AXUIElementCreateSystemWide()
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        let role = stringAttr(el, kAXRoleAttribute) ?? ""
        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if editableRoles.contains(role) { return el }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return el
        }
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           role != "AXSlider", role != "AXCheckBox" {
            return el
        }
        return nil
    }

    private static func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Fallback: save the clipboard, paste, then restore it, so the user's clipboard is unchanged afterwards.
    static func pasteViaClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            let items = saved.map { d -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (t, data) in d { it.setData(data, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }
}
