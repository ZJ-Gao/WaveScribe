import Foundation
import FluidAudio

/// Splits a growing recording at pauses so earlier parts can be transcribed while the user is still speaking.
/// Pauses come from Silero VAD (speech probability per 256 ms block), which works even with a quiet mic.
enum Chunker {
    static let rate = 16000
    static let block = VadManager.chunkSize       // 4096 samples = 256 ms
    static let minChunk = 8 * rate                // don't cut before 8 s of pending audio
    static let forceChunk = 25 * rate             // must cut before Whisper's 30 s window
    static let silenceProb: Float = 0.3
    static let speechProb: Float = 0.5
    static let minPauseBlocks = 2                 // ~0.5 s

    /// `probs` are VAD probabilities for consecutive blocks starting at the pending region.
    /// Returns a cut position in samples relative to the start of the pending region.
    static func findCut(probs: [Float], pending: Int) -> Int? {
        guard pending >= minChunk else { return nil }
        let start = 5 * rate / block
        let end = probs.count - 1                 // ignore the newest block, it may be partial
        var best: Int?
        var run = 0
        if end > start {
            for i in start..<end {
                if probs[i] < silenceProb { run += 1 } else {
                    if run >= minPauseBlocks { best = i - run / 2 }
                    run = 0
                }
            }
        }
        if let best { return best * block }
        if pending >= forceChunk {
            let lo = 15 * rate / block
            guard lo < probs.count else { return forceChunk }
            let idx = (lo..<probs.count).min { probs[$0] < probs[$1] } ?? lo
            return idx * block
        }
        return nil
    }

    static func hasSpeech(_ probs: [Float]) -> Bool { probs.contains { $0 > speechProb } }

    /// Join segment texts: no space between Chinese, a space between Latin words.
    static func join(_ parts: [String]) -> String {
        var out = ""
        let enders: Set<Character> = ["。", "？", "！", ".", "?", "!", "，", ",", "；", ";", "…"]
        for p in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
            // A piece ends at a pause, which is often mid-sentence; if Whisper left it open, a comma is safer.
            if let last = out.last, !enders.contains(last) { out += last.isASCII ? "," : "，" }
            if let last = out.last, let first = p.first, last.isASCII, last != " " { out += " " }
            out += p
        }
        return out
    }
}

/// Runs one dictation: cuts at pauses during recording and transcribes pieces in order in the background.
@MainActor
final class ChunkedSession {
    private let transcriber: Transcriber
    private let vad: VadManager?
    private let snapshot: () -> [Float]
    private var committed = 0
    private var texts: [String] = []
    private var chain: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private(set) var chunkCount = 0
    private var pendingLang: Task<String, Never>?
    private var lastLang = "zh"

    init(transcriber: Transcriber, vad: VadManager?, snapshot: @escaping () -> [Float]) {
        self.transcriber = transcriber
        self.vad = vad
        self.snapshot = snapshot
    }

    func start() {
        guard let vad else { return }             // no VAD: transcribe everything at the end
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                let s = self.snapshot()
                let from = self.committed
                // Detect the language of the current piece once it has 2 s of audio.
                if self.pendingLang == nil, s.count - from >= 2 * Chunker.rate {
                    let head = Array(s[from...])
                    let t = self.transcriber
                    let fallback = self.lastLang
                    self.pendingLang = Task { (try? await t.detectLanguage(head)) ?? fallback }
                }
                guard s.count - from >= Chunker.minChunk else { continue }
                let pending = Array(s[from...])
                guard let probs = try? await vad.process(pending).map(\.probability) else { continue }
                if let cut = Chunker.findCut(probs: probs, pending: pending.count), cut > 0, !Task.isCancelled {
                    self.enqueue(Array(pending[0..<min(cut, pending.count)]))
                    self.committed = from + cut
                }
            }
        }
    }

    func enqueue(_ segment: [Float]) {
        let prev = chain
        let idx = texts.count
        texts.append("")
        chunkCount += 1
        let langTask = pendingLang
        pendingLang = nil
        chain = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            let lang = await Self.language(self.transcriber, segment, early: langTask?.value, fallback: self.lastLang)
            self.lastLang = lang
            let context = idx > 0 ? self.texts[idx - 1] : ""
            self.texts[idx] = await Self.transcribe(self.transcriber, segment, context: context, language: lang)
        }
    }

    /// `early` is the guess from the piece's first 2 s. Decoding Chinese speech as English makes Whisper
    /// translate it, while decoding English as Chinese keeps it English, so an English guess is checked again
    /// on the whole piece. With no guess, detect on the piece, or reuse the previous language under 1 s.
    nonisolated static func language(_ t: Transcriber, _ seg: [Float], early: String?, fallback: String) async -> String {
        if let early, early != "en" || seg.count < 3 * Chunker.rate { return early }
        guard seg.count >= Chunker.rate else { return fallback }
        return (try? await t.detectLanguage(seg)) ?? early ?? fallback
    }

    /// Retry without context if the context made Whisper return only punctuation.
    nonisolated static func transcribe(_ t: Transcriber, _ seg: [Float], context: String, language: String) async -> String {
        let text = (try? await t.transcribeSegment(seg, context: context, language: language)) ?? ""
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if letters == 0 && !context.isEmpty {
            return (try? await t.transcribeSegment(seg, context: "", language: language)) ?? ""
        }
        return text
    }

    /// Abandon this dictation: stop cutting; pieces already being transcribed are ignored.
    func cancel() { monitor?.cancel(); pendingLang?.cancel() }

    /// Call with the full recording after it stops. Returns the joined, formatted text.
    func finish(_ all: [Float]) async -> String {
        monitor?.cancel()
        await monitor?.value
        if committed < all.count {
            let tail = Array(all[committed...])
            var speech = true
            if committed > 0, let vad, let probs = try? await vad.process(tail).map(\.probability) {
                speech = Chunker.hasSpeech(probs)
            }
            if speech { enqueue(tail) }
        }
        await chain?.value
        let text = await Punctuator.shared.punctuate(Chunker.join(texts))
        return Rules.apply(Transcriber.format(text))
    }
}
