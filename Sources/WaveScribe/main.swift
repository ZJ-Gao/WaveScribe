@preconcurrency import WhisperKit
import FluidAudio
import AppKit
import SwiftUI
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var state: AppState!
    var hotkey: Hotkey?
    var modifierKey: ModifierKey?
    var hud: RecordingHUD?
    var toggleItem: NSMenuItem?
    var prefsWindow: NSWindow?
    var testWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        state = AppState()
        installMainMenu()
        _ = HistoryStore.shared

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic")
        let menu = NSMenu()
        menu.addItem(withTitle: "打开窗口", action: #selector(openTest), keyEquivalent: "t")
        toggleItem = menu.addItem(withTitle: "开始/结束录音", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: "打开数据文件夹", action: #selector(openData), keyEquivalent: "")
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        let rec = state.recorder
        hud = RecordingHUD(level: { rec.level })
        state.onStatusChange = { [weak self] s in
            switch s {
            case .recording: self?.setIcon("mic.fill"); self?.hud?.showRecording()
            case .transcribing: self?.setIcon("waveform"); self?.hud?.showTranscribing()
            case .warming: self?.setIcon("hourglass"); self?.hud?.hide()
            case .downloading: self?.setIcon("arrow.down.circle"); self?.hud?.hide()
            case .error(let msg):
                self?.setIcon("exclamationmark.triangle")
                if msg.contains("麦克风") { self?.hud?.showMessage(msg) } else { self?.hud?.hide() }
            case .idle: self?.setIcon("mic"); self?.hud?.hide()
            }
        }
        registerHotkey()
        Settings.shared.onShortcutChange = { [weak self] in self?.registerHotkey() }
        Settings.shared.onEngineChange = { [weak self] in Task { await self?.state.engineChanged() } }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !Inserter.hasAccessibility { Inserter.requestAccessibility() }
        openTest()
    }

    /// The standard menu bar (WaveScribe, Edit) shown next to the Apple menu while a window is open.
    /// The Edit menu also gives the text fields their Cut/Copy/Paste/Select All/Undo shortcuts.
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "WaveScribe")
        appMenu.addItem(withTitle: "关于 WaveScribe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 WaveScribe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 WaveScribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)

        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)

        let winItem = NSMenuItem(); let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win; main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    /// Show a window as a regular app (menu bar + Dock icon); go back to menu-bar-only when all are closed.
    func present(_ w: NSWindow?) {
        guard let w else { return }
        w.delegate = self
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ note: Notification) {
        DispatchQueue.main.async {
            let open = [self.testWindow, self.prefsWindow].contains { $0?.isVisible == true }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func setIcon(_ name: String) {
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "WaveScribe")
    }

    @objc func toggle() { state.toggle() }

    func registerHotkey() {
        unregisterHotkey()
        let s = Settings.shared
        let hold = s.triggerMode == .hold
        if s.isModifierOnly {
            modifierKey = ModifierKey(carbonModifier: s.modifiers, hold: hold,
                                      onStart: { [weak self] in hold ? self?.state.holdStart() : self?.state.toggle() },
                                      onStop: { [weak self] in self?.state.holdStop() })
        } else if hold {
            hotkey = Hotkey(keyCode: s.keyCode, modifiers: s.modifiers, onRelease: { [weak self] in self?.state.holdStop() }) { [weak self] in
                self?.state.holdStart()
            }
        } else {
            hotkey = Hotkey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in self?.state.toggle() }
        }
        toggleItem?.title = "开始/结束录音  (\(s.shortcutText))"
    }

    func unregisterHotkey() {
        hotkey?.unregister(); hotkey = nil
        modifierKey?.unregister(); modifierKey = nil
    }

    @objc func openPreferences() {
        if prefsWindow == nil {
            let view = PreferencesView(onCaptureChange: { [weak self] capturing in
                // Pause the global shortcut while a new one is typed, so it reaches the recorder.
                if capturing { self?.unregisterHotkey() } else { self?.registerHotkey() }
            })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "偏好设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            prefsWindow = w
        }
        present(prefsWindow)
    }

    @objc func openData() { NSWorkspace.shared.open(Paths.dataDir) }

    @objc func openTest() {
        if testWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "声波转存 WaveScribe"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TestView(state: state))
            w.center()
            testWindow = w
            state.testWindow = w
        }
        present(testWindow)
    }
}

// Test mode: WaveScribe --suggest prints learning suggestions from the correction log.
if CommandLine.arguments.contains("--suggest") {
    for row in CorrectionLog.references() {
        if let raw = (try? String(contentsOf: Paths.corrections, encoding: .utf8))?.split(separator: "\n").compactMap({ (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }).last(where: { ($0["audio"] as? String) == row.audio })?["raw"] as? String {
            for s in Suggestions.from(raw: raw, edited: row.reference) { print(row.audio, "「\(s.wrong)」→「\(s.right)」   rule:「\(s.ruleWrong)」→「\(s.ruleRight)」") }
        }
    }
    exit(0)
}

// Test mode: WaveScribe --purge runs the 24-hour cleanup once (use VT_DATA_DIR on a copy) and prints what is left.
if CommandLine.arguments.contains("--purge") {
    MainActor.assumeIsolated {
        HistoryStore.shared.purge()
        let audio = (try? FileManager.default.contentsOfDirectory(atPath: Paths.audioDir.path))?.count ?? 0
        let rows = ((try? String(contentsOf: Paths.corrections, encoding: .utf8)) ?? "").split(separator: "\n").count
        print("retention \(Settings.currentRetention.rawValue): \(HistoryStore.shared.entries.count) history, \(rows) log rows, \(audio) recordings")
    }
    exit(0)
}

// Test mode: WaveScribe --chunked a.wav simulates live chunking and reports the wait after "stop".
if let i = CommandLine.arguments.firstIndex(of: "--chunked") {
    let files = Array(CommandLine.arguments[(i + 1)...])
    let sem = DispatchSemaphore(value: 0)
    Task {
        let t = Transcriber()
        let vad = try? await VadManager()
        _ = try? await t.transcribe([Float](repeating: 0, count: 16000))
        for f in files {
            let all = (try? AudioProcessor.loadAudioAsFloatArray(fromPath: f)) ?? []
            var committed = 0
            var texts: [String] = []
            var cuts: [String] = []
            var lang: String? = nil
            var lastLang = "zh"
            var end = 8000
            while end < all.count {
                if lang == nil, end - committed >= 32000 { lang = try? await t.detectLanguage(Array(all[committed..<end])) }
                if end - committed >= Chunker.minChunk, let vad {
                    let pending = Array(all[committed..<end])
                    let probs = (try? await vad.process(pending).map(\.probability)) ?? []
                    if let cut = Chunker.findCut(probs: probs, pending: pending.count), cut > 0 {
                        let seg = Array(pending[0..<min(cut, pending.count)])
                        let l = await ChunkedSession.language(t, seg, early: lang, fallback: lastLang)
                        texts.append(await ChunkedSession.transcribe(t, seg, context: texts.last ?? "", language: l))
                        lastLang = l; lang = nil
                        committed += cut
                        cuts.append(String(format: "%.1f", Double(committed) / 16000))
                    }
                }
                end += 8000
            }
            let t0 = Date()
            let tail = Array(all[committed...])
            let probs = (try? await vad?.process(tail).map(\.probability)) ?? [1]
            if committed == 0 || Chunker.hasSpeech(probs) {
                let l = await ChunkedSession.language(t, tail, early: lang, fallback: lastLang)
                texts.append(await ChunkedSession.transcribe(t, tail, context: texts.last ?? "", language: l))
            }
            let wait = Date().timeIntervalSince(t0)
            print("\((f as NSString).lastPathComponent)\t\(String(format: "%.1fs audio", Double(all.count) / 16000))\tcuts at [\(cuts.joined(separator: ", "))]\twait after stop \(String(format: "%.2fs", wait))\n  \(Transcriber.format(await Punctuator.shared.punctuate(Chunker.join(texts))))")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Test mode: WaveScribe --transcribe a.wav b.wav ... prints results and exits.
if let i = CommandLine.arguments.firstIndex(of: "--transcribe") {
    let files = Array(CommandLine.arguments[(i + 1)...])
    let sem = DispatchSemaphore(value: 0)
    Task {
        let t = Transcriber()
        for f in files {
            let samples = (try? AudioProcessor.loadAudioAsFloatArray(fromPath: f)) ?? []
            let t0 = Date()
            let text = (try? await t.transcribe(samples)) ?? "<error>"
            print("\((f as NSString).lastPathComponent)\t\(String(format: "%.2fs", Date().timeIntervalSince(t0)))\t\(text)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated {
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
}
app.run()
