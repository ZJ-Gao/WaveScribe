import AppKit
import Carbon
import SwiftUI
import FluidAudio
@preconcurrency import WhisperKit

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable { case idle, recording, transcribing, warming, downloading(Double), error(String) }

    @Published var status: Status = .idle
    @Published var modelLoaded = false
    @Published var memoryMB: Double = 0
    @Published var newestInWindow: UUID?
    @Published var validating = false
    @Published var validationProgress = ""
    @Published var validation: [ValidationRow] = []
    @Published var accessibilityOK = Inserter.hasAccessibility

    let recorder = Recorder()
    let transcriber = Transcriber()
    weak var testWindow: NSWindow?
    var onStatusChange: ((Status) -> Void)?
    private var recordStart = Date()
    private var session: ChunkedSession?
    private var escKey: Hotkey?
    private var vad: VadManager?

    init() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshStats() }
        }
        Task { await downloadModel() }
        Task { await Punctuator.shared.ensureDownloaded() }
        Task { self.vad = try? await VadManager() }
    }

    private func set(_ s: Status) {
        status = s
        // Esc cancels a recording; it is only captured while recording, so other apps keep it otherwise.
        if s == .recording, escKey == nil {
            escKey = Hotkey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.cancelRecording() }
        } else if s != .recording {
            escKey?.unregister(); escKey = nil
        }
        onStatusChange?(s)
    }

    /// Stop recording and throw the audio away: nothing is transcribed, pasted or saved.
    func cancelRecording() {
        guard status == .recording else { return }
        _ = recorder.stop()
        session?.cancel()
        session = nil
        set(.idle)
    }

    func refreshStats() async {
        memoryMB = Self.footprintMB()
        modelLoaded = await transcriber.isLoaded
        accessibilityOK = Inserter.hasAccessibility
    }

    func downloadModel() async {
        if Settings.currentEngine == .qwen {
            if FileManager.default.fileExists(atPath: Transcriber.qwenReady.path) { set(.idle); return }
            set(.downloading(0))
            do {
                _ = try await transcriber.loadQwen { p in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.status { self?.set(.downloading(p)) }
                    }
                }
                await transcriber.scheduleUnload()
                set(.idle)
            } catch {
                set(.error(L("模型下载失败：", "Model download failed: ") + error.localizedDescription))
            }
            return
        }
        set(.downloading(0))
        do {
            _ = try await transcriber.ensureDownloaded { p in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.status { self?.set(.downloading(p)) }
                }
            }
            // First load compiles the CoreML model for this Mac (slow once, cached afterwards).
            let marker = Paths.modelsDir.appendingPathComponent(".warmed")
            if !FileManager.default.fileExists(atPath: marker.path) {
                set(.warming)
                await transcriber.preload()
                _ = try? await transcriber.transcribe([Float](repeating: 0, count: 16000))
                await transcriber.unload()
                FileManager.default.createFile(atPath: marker.path, contents: nil)
            }
            set(.idle)
        } catch {
            set(.error(L("模型下载失败：", "Model download failed: ") + error.localizedDescription))
        }
    }

    /// The user picked another speech model: free the old one and fetch the new one if needed.
    func engineChanged() async {
        await transcriber.unload()
        await downloadModel()
    }

    /// Hold-to-talk: start on press (if not already busy), stop on release.
    func holdStart() {
        if validating { NSSound.beep(); return }
        if case .idle = status { startRecording() } else if case .error = status { startRecording() }
    }
    func holdStop() {
        if status == .recording { stopRecording() }
    }

    func toggle() {
        if validating { NSSound.beep(); return }
        switch status {
        case .idle, .error: startRecording()
        case .recording: stopRecording()
        default: NSSound.beep()
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
            recordStart = Date()
            set(.recording)
            Task { await transcriber.preload() }
            Task { await Punctuator.shared.preload() }
            let rec = recorder
            session = ChunkedSession(transcriber: transcriber, vad: vad, snapshot: { rec.snapshot() })
            session?.start()
            // A present but dead microphone delivers only silence. Check once in the background, so a working
            // microphone loses no time. Bluetooth headsets such as AirPods can take a second or two to switch
            // their microphone on, so they get longer.
            let started = recordStart
            let wait: UInt64 = Recorder.defaultInputIsBluetooth ? 3_000_000_000 : 1_000_000_000
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: wait)
                guard let self, self.status == .recording, self.recordStart == started,
                      self.recorder.peak <= 0.0005 else { return }
                _ = self.recorder.stop()
                self.session?.cancel(); self.session = nil
                self.set(.error(L("没有检测到声音，请检查麦克风", "No sound detected. Check your microphone.")))
            }
        } catch {
            set(.error(error is Recorder.NoMicrophone ? L("没有检测到麦克风", "No microphone found") : L("麦克风启动失败：", "Microphone failed to start: ") + error.localizedDescription))
        }
    }

    private func stopRecording() {
        let peak = recorder.peak
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16000
        guard seconds > 0.3 else { session = nil; set(.idle); return }
        guard peak > 0.0005 else {
            session?.cancel(); session = nil
            set(.error(L("没有检测到声音，请检查麦克风", "No sound detected. Check your microphone.")))
            return
        }
        set(.transcribing)
        let fileName = "\(Int(Date().timeIntervalSince1970)).wav"
        Recorder.writeWav(samples, to: Paths.audioDir.appendingPathComponent(fileName))
        let t0 = Date()
        let current = session
        session = nil
        Task {
            let text = await current?.finish(samples) ?? ""
            let latency = Date().timeIntervalSince(t0)
            if text.isEmpty { set(.error(L("没有识别出文字", "No speech recognized"))) } else { set(.idle) }
            deliver(text, audio: fileName, seconds: seconds, latency: latency)
            await refreshStats()
        }
    }

    private func deliver(_ text: String, audio: String, seconds: Double, latency: Double) {
        guard !text.isEmpty else { return }
        func record(_ target: String) -> HistoryEntry {
            HistoryStore.shared.add(HistoryEntry(date: Date(), raw: text, audioFile: audio,
                                                 audioSeconds: seconds, latency: latency, target: target))
        }
        if NSApp.isActive, let w = testWindow, w.isKeyWindow {
            newestInWindow = record("window").id
            return
        }
        if !Inserter.hasAccessibility { Inserter.requestAccessibility() }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        if Inserter.insert(text) == .noTextField {
            _ = record("popup")
            ResultPanel.show(text)
        } else {
            _ = record(appName)
        }
    }

    /// Re-transcribe every saved recording with and without the vocabulary and rules,
    /// and count character errors against the user's corrected text.
    func validate() {
        guard !validating, status == .idle || { if case .error = status { return true } else { return false } }() else { NSSound.beep(); return }
        validating = true
        validation = []
        let items = CorrectionLog.references()
        Task {
            for (n, item) in items.enumerated() {
                validationProgress = "\(n + 1)/\(items.count)"
                let url = Paths.audioDir.appendingPathComponent(item.audio)
                guard let samples = try? AudioProcessor.loadAudioAsFloatArray(fromPath: url.path) else { continue }
                let before = (try? await transcriber.transcribeWhole(samples, custom: false)) ?? ""
                let after = (try? await transcriber.transcribeWhole(samples, custom: true)) ?? ""
                validation.append(ValidationRow(audio: item.audio, reference: item.reference,
                                                before: before, after: after,
                                                errorsBefore: CER.errors(before, item.reference),
                                                errorsAfter: CER.errors(after, item.reference),
                                                length: CER.normalize(item.reference).count))
            }
            validating = false
            validationProgress = ""
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
