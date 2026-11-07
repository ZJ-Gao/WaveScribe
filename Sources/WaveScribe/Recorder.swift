import AVFoundation
import CoreAudio

/// Records microphone audio and returns 16 kHz mono Float samples.
final class Recorder {
    /// A new engine for each recording, so it uses whatever microphone is the default right now
    /// (an engine keeps the format of the device it first saw, e.g. 48 kHz built-in vs 16 or 24 kHz AirPods).
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var samples: [Float] = []
    private var inputRate: Double = 48000
    private let lock = NSLock()
    /// Current input loudness (RMS of the latest buffer), for the recording indicator.
    private(set) var level: Float = 0
    /// Loudest buffer RMS seen in this recording, to detect a dead or silent microphone.
    private(set) var peak: Float = 0

    struct NoMicrophone: LocalizedError {
        var errorDescription: String? { L("没有检测到麦克风", "No microphone found") }
    }

    func start() throws {
        lock.lock(); samples.removeAll(); peak = 0; lock.unlock()
        guard AVCaptureDevice.default(for: .audio) != nil,
              AVCaptureDevice.authorizationStatus(for: .audio) != .denied else { throw NoMicrophone() }
        engine = AVAudioEngine()
        try startEngine()
        // Bluetooth headsets switch to a different format (and sometimes device) as recording starts,
        // which stops the engine. Restart it on the new format and keep what was recorded.
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            let oldRate = self.inputRate
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            try? self.startEngine()
            if self.inputRate != oldRate {
                self.lock.lock()
                self.samples = Self.resample(self.samples, from: oldRate, to: self.inputRate)
                self.lock.unlock()
            }
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
        lock.lock(); inputRate = format.sampleRate; lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            self.level = n > 0 ? (sum / Float(n)).squareRoot() : 0
            self.peak = max(self.peak, self.level)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
    }

    /// Audio captured so far, at 16 kHz, without stopping.
    func snapshot() -> [Float] {
        lock.lock(); let raw = samples; let rate = inputRate; lock.unlock()
        return Self.resample(raw, from: rate, to: 16000)
    }

    func stop() -> [Float] {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let raw = samples; let rate = inputRate; samples.removeAll(); lock.unlock()
        return Self.resample(raw, from: rate, to: 16000)
    }

    /// Whether the current default input is a Bluetooth device (e.g. AirPods).
    static var defaultInputIsBluetooth: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        if from == to { return input }
        let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(input.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }
        let cap = AVAudioFrameCount(Double(input.count) * to / from + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return [] }
        var done = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    static func writeWav(_ samples: [Float], to url: URL) {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buf)
    }
}
