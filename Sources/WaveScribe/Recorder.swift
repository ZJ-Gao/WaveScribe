import AVFoundation

/// Records microphone audio and returns 16 kHz mono Float samples.
final class Recorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var inputRate: Double = 48000
    private let lock = NSLock()
    /// Current input loudness (RMS of the latest buffer), for the recording indicator.
    private(set) var level: Float = 0
    /// Loudest buffer RMS seen in this recording, to detect a dead or silent microphone.
    private(set) var peak: Float = 0

    struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "没有检测到麦克风" }
    }

    func start() throws {
        lock.lock(); samples.removeAll(); peak = 0; lock.unlock()
        guard AVCaptureDevice.default(for: .audio) != nil,
              AVCaptureDevice.authorizationStatus(for: .audio) != .denied else { throw NoMicrophone() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
        inputRate = format.sampleRate
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
        lock.lock(); let raw = samples; lock.unlock()
        return Self.resample(raw, from: inputRate, to: 16000)
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let raw = samples; samples.removeAll(); lock.unlock()
        return Self.resample(raw, from: inputRate, to: 16000)
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
