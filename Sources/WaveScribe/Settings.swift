import AppKit
import Carbon
import SwiftUI

/// The interface text in Chinese or English, following the language setting.
nonisolated func L(_ zh: String, _ en: String) -> String { Settings.isChinese ? zh : en }

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

    /// Interface language: follow the system (Chinese if the first preferred language is Chinese, else English), or fixed.
    enum Language: String, CaseIterable { case system, zh, en }
    nonisolated static let languageKey = "language"
    @Published var language: Language {
        didSet {
            guard language != oldValue else { return }
            d.set(language.rawValue, forKey: Self.languageKey)
            onLanguageChange?()
        }
    }
    /// Called after the language changes so menus and window titles can be rebuilt.
    var onLanguageChange: (() -> Void)?
    nonisolated static var isChinese: Bool {
        switch Language(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system {
        case .zh: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

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
        language = Language(rawValue: d.string(forKey: Self.languageKey) ?? "") ?? .system
        triggerMode = TriggerMode(rawValue: d.string(forKey: "triggerMode") ?? "") ?? .toggle
    }

    /// keyCode value meaning "this modifier key on its own", e.g. just ⌥.
    static let modifierOnly: UInt32 = 0xFFFF
    var isModifierOnly: Bool { keyCode == Self.modifierOnly }
    var shortcutText: String { isModifierOnly ? Self.symbols(modifiers) + L("（单独按）", " (on its own)") : Self.symbols(modifiers) + keyName }

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
    @AppStorage(HUDPosition.key) private var hudPosition = HUDPosition.bottomCenter.raw
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var hint = ""
    /// Lets the app pause the global hotkey while a new one is being typed.
    var onCaptureChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("快捷键", "Shortcut")).font(.headline)
            HStack {
                Text(L("开始/结束录音", "Start/stop recording"))
                Spacer()
                Button(capturing ? L("请按下新的快捷键…", "Press the new shortcut…") : settings.shortcutText) {
                    capturing ? stopCapture() : startCapture()
                }
                .frame(minWidth: 150)
                Button(L("恢复默认", "Reset")) { settings.resetShortcut() }.disabled(capturing)
            }
            Text(hint.isEmpty ? L("可以是组合键（至少一个修饰键），也可以单独按一下 ⌃ ⌥ ⇧ ⌘ 中的一个；F1 到 F12 可以单独使用。录音时按 Esc 取消。", "A key combination with at least one modifier, or one of ⌃ ⌥ ⇧ ⌘ pressed on its own; F1 to F12 work alone. Press Esc while recording to cancel.") : hint)
                .font(.caption).foregroundStyle(hint.isEmpty ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $settings.triggerMode) {
                Text(L("按一下开始，再按一下结束", "Press to start, press again to stop")).tag(Settings.TriggerMode.toggle)
                Text(L("按住说话，松开结束", "Hold to talk, release to stop")).tag(Settings.TriggerMode.hold)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(capturing)
            Divider().padding(.vertical, 4)
            Text(L("识别模型", "Recognition model")).font(.headline)
            Picker("", selection: $settings.engine) {
                Text(L("千问（中文、中英混说）", "Qwen (Chinese, mixed Chinese-English)")).tag(Settings.Engine.qwen)
                Text(L("Whisper（全英文）", "Whisper (English only)")).tag(Settings.Engine.whisper)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Divider().padding(.vertical, 4)
            Text(L("录音保留", "Keep recordings")).font(.headline)
            Picker("", selection: $settings.retention) {
                Text(L("只保留改过的（推荐）", "Only ones I corrected (recommended)")).tag(Settings.Retention.edited)
                Text(L("全部保留", "All")).tag(Settings.Retention.all)
                Text(L("24 小时后全部删除", "Delete all after 24 hours")).tag(Settings.Retention.none)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(L("历史记录只显示最近 24 小时。超过 24 小时的录音：改过文字的可以留作测试答案，用来比较模型；其余按这里的选择处理。所有录音都只存在本机。", "History shows the last 24 hours. Older recordings whose text you corrected can be kept as test answers for comparing models; the rest follow this choice. All recordings stay on this Mac."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle(L("转写时显示敲木鱼的动画（关掉则显示转圈）", "Show the wooden fish animation while transcribing (off: a spinner)"), isOn: $muyu)
            Divider().padding(.vertical, 4)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("录音提示窗位置", "Recording indicator position")).font(.headline)
                    Text(L("点一个格子，提示窗会在那里显示两秒。", "Click a cell to see the indicator there for two seconds."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                PositionGrid(selection: $hudPosition)
            }
            Divider().padding(.vertical, 4)
            HStack {
                Text(L("界面语言", "Language")).font(.headline)
                Spacer()
                Picker("", selection: $settings.language) {
                    Text(L("跟随系统", "System")).tag(Settings.Language.system)
                    Text("中文").tag(Settings.Language.zh)
                    Text("English").tag(Settings.Language.en)
                }
                .labelsHidden().fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480, height: 650, alignment: .topLeading)
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
                hint = L("请同时按住 ⌃、⌥、⇧ 或 ⌘ 中的至少一个。", "Hold at least one of ⌃, ⌥, ⇧ or ⌘.")
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

/// A small picture of the screen split into 3 x 3 cells; the chosen cell is where the recording pill appears.
struct PositionGrid: View {
    @Binding var selection: String
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3) { column in
                        let cell = HUDPosition(row: row, column: column).raw
                        Button {
                            selection = cell
                            NotificationCenter.default.post(name: .hudPreview, object: nil)
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selection == cell ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 34, height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.5)))
    }
}

extension Notification.Name {
    static let hudPreview = Notification.Name("WaveScribeHUDPreview")
}
