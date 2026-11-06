import Carbon
import AppKit

/// Global hotkeys via Carbon. Each instance registers one key combination; `unregister()` releases it.
/// `onRelease` fires when the key is let go, which hold-to-talk needs.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private static var registry: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey),
         onRelease: @escaping () -> Void = {}, action: @escaping () -> Void) {
        self.onPress = action
        self.onRelease = onRelease
        self.id = Hotkey.nextID
        Hotkey.nextID += 1
        Hotkey.installHandlerOnce()
        Hotkey.registry[id] = self
        let hk = EventHotKeyID(signature: OSType(0x57565343), id: id)
        RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Hotkey.registry[id] = nil
    }

    private static func installHandlerOnce() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                guard let h = Hotkey.registry[id] else { return }
                released ? h.onRelease() : h.onPress()
            }
            return noErr
        }, 2, &specs, nil, &handler)
    }
}

/// A single modifier key (⌃ ⌥ ⇧ or ⌘) used on its own as the shortcut. Carbon cannot register these,
/// so key events are watched instead (global monitors need the Accessibility permission the app already asks for).
/// The key only counts when nothing else is pressed with it, so ⌥+letter and other combinations keep working.
@MainActor
final class ModifierKey {
    /// Tap: press and release within this time, with no other key in between.
    static let tapWindow: TimeInterval = 0.5
    /// Hold: start once held this long with no other key, so a quick ⌥+letter never opens the microphone.
    static let holdDelay: TimeInterval = 0.3

    private let flag: NSEvent.ModifierFlags
    private let hold: Bool
    private let onStart: () -> Void
    private let onStop: () -> Void
    private var monitors: [Any] = []
    private var downAt: Date?
    private var clean = false
    private var holding = false
    private var holdTimer: Timer?

    /// `hold`: `onStart` after holding, `onStop` on release. Otherwise `onStart` on each clean tap.
    init(carbonModifier: UInt32, hold: Bool, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        flag = Self.flag(carbonModifier)
        self.hold = hold
        self.onStart = onStart
        self.onStop = onStop
        let flags: (NSEvent) -> Void = { [weak self] e in MainActor.assumeIsolated { self?.flagsChanged(e) }; return }
        let key: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.otherKey() }; return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(m) }
        // Global monitors miss events sent to this app's own windows.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0); return $0 }) { monitors.append(m) }
    }

    func unregister() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        holdTimer?.invalidate()
    }

    private func flagsChanged(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.control, .option, .shift, .command])
        if mods == flag, downAt == nil {
            downAt = Date()
            clean = true
            if hold {
                holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.clean, self.downAt != nil else { return }
                        self.holding = true
                        self.onStart()
                    }
                }
            }
        } else if mods.isEmpty, let downAt {
            holdTimer?.invalidate()
            if hold {
                if holding { onStop() }
            } else if clean, Date().timeIntervalSince(downAt) < Self.tapWindow {
                onStart()
            }
            self.downAt = nil
            holding = false
        } else if downAt != nil {
            otherKey()    // another modifier joined in: this is a combination, not our key
        }
    }

    private func otherKey() {
        guard downAt != nil, !holding else { return }
        clean = false
        holdTimer?.invalidate()
    }

    static func flag(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        if carbon & UInt32(controlKey) != 0 { return .control }
        if carbon & UInt32(shiftKey) != 0 { return .shift }
        if carbon & UInt32(cmdKey) != 0 { return .command }
        return .option
    }
}
