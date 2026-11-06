import AppKit
import Carbon
import SwiftUI

/// User preferences, stored in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Carbon key code and modifier mask of the record shortcut. Default: Option + Space.
    @Published private(set) var keyCode: UInt32
    @Published private(set) var modifiers: UInt32
    @Published private(set) var keyName: String
    /// Called after the shortcut changes so the global hotkey can be re-registered.
    var onShortcutChange: (() -> Void)?

    /// Speech model. Qwen3-ASR by default (Chinese and mixed speech); Whisper for all-English dictation.
    enum Engine: String, CaseIterable { case qwen, whisper }
    nonisolated static let engineKey = "engine"
    @Published var engine: Engine {
        didSet {
            guard engine != oldValue else { return }
            d.set(engine.rawValue, forKey: Self.engineKey)
            onEngineChange?()
        }
    }
    /// Called after the engine changes so the old model can be unloaded and the new one fetched.
    var onEngineChange: (() -> Void)?

    /// What happens to recordings once they leave the 24-hour history.
    enum Retention: String, CaseIterable { case edited, all, none }
    nonisolated static let retentionKey = "retention"
    @Published var retention: Retention {
        didSet {
            guard retention != oldValue else { return }
            d.set(retention.rawValue, forKey: Self.retentionKey)
            HistoryStore.shared.purge()
        }
    }
    nonisolated static var currentRetention: Retention {
        Retention(rawValue: UserDefaults.standard.string(forKey: retentionKey) ?? "") ?? .edited
    }

    /// Readable from any thread (the transcriber runs off the main actor).
    nonisolated static var currentEngine: Engine {
        let raw = ProcessInfo.processInfo.environment["VT_ENGINE"] ?? UserDefaults.standard.string(forKey: engineKey) ?? ""
        return Engine(rawValue: raw) ?? .qwen
    }

    init() {
        let hasSaved = d.object(forKey: "hotkeyCode") != nil
        keyCode = hasSaved ? UInt32(d.integer(forKey: "hotkeyCode")) : UInt32(kVK_Space)
        modifiers = hasSaved ? UInt32(d.integer(forKey: "hotkeyMods")) : UInt32(optionKey)
        keyName = d.string(forKey: "hotkeyName") ?? "Space"
        engine = Self.currentEngine
        retention = Self.currentRetention
        triggerMode = TriggerMode(rawValue: d.string(forKey: "triggerMode") ?? "") ?? .toggle
    }

    /// keyCode value meaning "this modifier key on its own", e.g. just ⌥.
    static let modifierOnly: UInt32 = 0xFFFF
    var isModifierOnly: Bool { keyCode == Self.modifierOnly }
    var shortcutText: String { isModifierOnly ? Self.symbols(modifiers) + "（单独按）" : Self.symbols(modifiers) + keyName }

    /// Tap to start and tap again to stop, or hold to talk and release to stop.
    enum TriggerMode: String, CaseIterable { case toggle, hold }
    @Published var triggerMode: TriggerMode {
        didSet {
            guard triggerMode != oldValue else { return }
            d.set(triggerMode.rawValue, forKey: "triggerMode")
            onShortcutChange?()
        }
    }

    func setShortcut(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyName = keyName
        d.set(Int(keyCode), forKey: "hotkeyCode")
        d.set(Int(modifiers), forKey: "hotkeyMods")
        d.set(keyName, forKey: "hotkeyName")
        onShortcutChange?()
    }

    func resetShortcut() { setShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyName: "Space") }

    static func symbols(_ m: UInt32) -> String {
        var s = ""
        if m & UInt32(controlKey) != 0 { s += "⌃" }
        if m & UInt32(optionKey) != 0 { s += "⌥" }
        if m & UInt32(shiftKey) != 0 { s += "⇧" }
        if m & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func keyName(_ e: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(e.keyCode)] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }

    static func isFunctionKey(_ code: UInt16) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            .contains(Int(code))
    }
}

struct PreferencesView: View {
    @ObservedObject var settings = Settings.shared
    @AppStorage("muyu") private var muyu = true
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var hint = ""
    /// Lets the app pause the global hotkey while a new one is being typed.
    var onCaptureChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷键").font(.headline)
            HStack {
                Text("开始/结束录音")
                Spacer()
                Button(capturing ? "请按下新的快捷键…" : settings.shortcutText) {
                    capturing ? stopCapture() : startCapture()
                }
                .frame(minWidth: 150)
                Button("恢复默认") { settings.resetShortcut() }.disabled(capturing)
            }
            Text(hint.isEmpty ? "可以是组合键（至少一个修饰键），也可以单独按一下 ⌃ ⌥ ⇧ ⌘ 中的一个；F1 到 F12 可以单独使用。录音时按 Esc 取消。" : hint)
                .font(.caption).foregroundStyle(hint.isEmpty ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $settings.triggerMode) {
                Text("按一下开始，再按一下结束").tag(Settings.TriggerMode.toggle)
                Text("按住说话，松开结束").tag(Settings.TriggerMode.hold)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(capturing)
            Divider().padding(.vertical, 4)
            Text("识别模型").font(.headline)
            Picker("", selection: $settings.engine) {
                Text("千问（中文、中英混说）").tag(Settings.Engine.qwen)
                Text("Whisper（全英文）").tag(Settings.Engine.whisper)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Divider().padding(.vertical, 4)
            Text("录音保留").font(.headline)
            Picker("", selection: $settings.retention) {
                Text("只保留改过的（推荐）").tag(Settings.Retention.edited)
                Text("全部保留").tag(Settings.Retention.all)
                Text("24 小时后全部删除").tag(Settings.Retention.none)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("历史记录只显示最近 24 小时。超过 24 小时的录音：改过文字的可以留作测试答案，用来比较模型；其余按这里的选择处理。所有录音都只存在本机。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle("转写时显示敲木鱼的动画（关掉则显示转圈）", isOn: $muyu)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 500, alignment: .topLeading)
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        capturing = true; hint = ""
        onCaptureChange(true)
        var lone: NSEvent.ModifierFlags = []    // a modifier pressed on its own, waiting for its release
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            if e.type == .flagsChanged {
                let mods = e.modifierFlags.intersection([.control, .option, .shift, .command])
                if [.control, .option, .shift, .command].contains(where: { mods == $0 }), lone.isEmpty {
                    lone = mods
                } else if mods.isEmpty, !lone.isEmpty {
                    settings.setShortcut(keyCode: Settings.modifierOnly, modifiers: Settings.carbonModifiers(lone), keyName: "")
                    stopCapture()
                } else if !mods.isEmpty, mods != lone {
                    lone = []    // two modifiers together: wait for a normal key to complete the combination
                }
                return e
            }
            lone = []
            if e.keyCode == UInt16(kVK_Escape) { stopCapture(); return nil }
            let mods = Settings.carbonModifiers(e.modifierFlags)
            guard mods != 0 || Settings.isFunctionKey(e.keyCode) else {
                hint = "请同时按住 ⌃、⌥、⇧ 或 ⌘ 中的至少一个。"
                return nil
            }
            settings.setShortcut(keyCode: UInt32(e.keyCode), modifiers: mods, keyName: Settings.keyName(e))
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if capturing { onCaptureChange(false) }
        capturing = false
    }
}
