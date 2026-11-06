import CoreML
import Foundation
@preconcurrency import Qwen3ASR
@preconcurrency import WhisperKit

/// Loads the selected speech model on demand (Qwen3-ASR by default, Whisper for all-English dictation)
/// and unloads it after a period of inactivity to keep idle memory low. Only one model is loaded at a time.
actor Transcriber {
    static let modelName = "openai_whisper-large-v3-v20240930_turbo"
    static let idleUnloadSeconds: UInt64 = 60

    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private var unloadTask: Task<Void, Never>?
    private var modelFolder: URL?

    var isLoaded: Bool { kit != nil || qwen != nil }

    // MARK: Qwen3-ASR

    static let qwenModelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    static var qwenFolder: URL { Paths.modelsDir.appendingPathComponent("qwen3-asr-0.6b-mlx-4bit", isDirectory: true) }
    /// Written after the first successful load, so a half-finished download is never mistaken for a complete one.
    static var qwenReady: URL { qwenFolder.appendingPathComponent(".complete") }
    private var qwen: Qwen3ASRModel?
    private var qwenLoading: Task<Qwen3ASRModel, Error>?
    nonisolated var usesQwen: Bool { Settings.currentEngine == .qwen }

    /// Download (about 680 MB, once) and load Qwen3-ASR.
    func loadQwen(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Qwen3ASRModel {
        unloadTask?.cancel()
        if let qwen { return qwen }
        if qwenLoading == nil {
            qwenLoading = Task {
                let m = try await Qwen3ASRModel.fromPretrained(modelId: Self.qwenModelId, cacheDir: Self.qwenFolder,
                                                               progressHandler: { p, _ in progress?(p) })
                FileManager.default.createFile(atPath: Self.qwenReady.path, contents: nil)
                return m
            }
        }
        do {
            let m = try await qwenLoading!.value
            qwen = m
            qwenLoading = nil
            return m
        } catch {
            qwenLoading = nil
            throw error
        }
    }

    /// Qwen3-ASR writes filler sounds as spoken; 呃 and 嗯 never carry meaning, so drop them.
    static func cleanQwen(_ s: String) -> String {
        clean(s.replacingOccurrences(of: "[呃嗯]+[，,、。]?", with: "", options: .regularExpression))
    }

    /// Download the model files once (no memory cost, files only).
    func ensureDownloaded(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let modelFolder { return modelFolder }
        let local = Paths.modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(Self.modelName)")
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("TextDecoder.mlmodelc").path) {
            modelFolder = local
            return local
        }
        let url = try await WhisperKit.download(variant: Self.modelName, downloadBase: Paths.modelsDir) { p in
            progress(p.fractionCompleted)
        }
        modelFolder = url
        return url
    }

    /// Start loading as soon as recording begins, so loading overlaps with speaking.
    func preload() {
        unloadTask?.cancel()
        if usesQwen {
            if qwen == nil, qwenLoading == nil { Task { _ = try? await self.loadQwen() } }
            return
        }
        if kit != nil || loading != nil { return }
        loading = Task {
            let folder = try await ensureDownloaded { _ in }
            let env = ProcessInfo.processInfo.environment["VT_ENC"]
            let enc: MLComputeUnits = env == "gpu" ? .cpuAndGPU : env == "all" ? .all : .cpuAndNeuralEngine
            let compute = ModelComputeOptions(audioEncoderCompute: enc)
            let config = WhisperKitConfig(modelFolder: folder.path, computeOptions: compute, verbose: false, logLevel: .error,
                                          prewarm: false, load: true, download: false)
            return try await WhisperKit(config)
        }
    }

    private func loadedKit() async throws -> WhisperKit {
        preload()
        let k: WhisperKit
        if let kit { k = kit } else {
            do {
                k = try await loading!.value
                kit = k
                loading = nil
            } catch {
                loading = nil
                throw error
            }
        }
        return k
    }

    // How languages are handled (tested on pure Chinese, pure English with technical terms, and mixed clips):
    // 1. Detect the language with no prompt, because any prompt biases detection.
    // 2. Decode with that language and a prompt led by the same language that also contains the other one,
    //    so the minority language is kept as spoken rather than translated.

    /// Serialises all model calls; WhisperKit is not safe to call concurrently.
    private var queueTail: Task<Void, Never>?
    private func serial<T>(_ op: @escaping () async throws -> T) async throws -> T {
        let prev = queueTail
        let task = Task { () async throws -> T in
            await prev?.value
            return try await op()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// "en" or "zh", detected on at most the first 30 s with no prompt.
    func detectLanguage(_ samples: [Float]) async throws -> String {
        if let forced = ProcessInfo.processInfo.environment["VT_LANGMODE"], forced != "auto" { return forced }
        if usesQwen { return "zh" }    // Qwen3-ASR handles Chinese, English and mixed speech without a language hint
        return try await serial {
            let k = try await self.loadedKit()
            let t0 = Date()
            let (top, probs) = try await k.detectLangauge(audioArray: Array(samples.prefix(30 * 16000)))
            if ProcessInfo.processInfo.environment["VT_DEBUG"] != nil {
                print(String(format: "detect %.1fs audio -> %@ (log p %.3f), %.2fs", Double(samples.count) / 16000, top, probs[top] ?? .nan, Date().timeIntervalSince(t0)))
            }
            return top == "en" ? "en" : "zh"
        }
    }

    /// Whole recording in one call (WhisperKit handles audio longer than 30 s itself). Used for validation.
    func transcribeWhole(_ samples: [Float], custom: Bool) async throws -> String {
        let lang = try await detectLanguage(samples)
        let t = Self.format(try await transcribeSegment(samples, context: "", language: lang, useVocabulary: custom))
        return custom ? Rules.apply(t) : t
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let lang = try await detectLanguage(samples)
        let text = await Punctuator.shared.punctuate(try await transcribeSegment(samples, context: "", language: lang))
        return Rules.apply(Self.format(text))
    }

    /// Transcribe one piece of a recording. `context` is the text of the previous piece,
    /// passed in the prompt so the pieces read as one passage.
    func transcribeSegment(_ samples: [Float], context: String, language: String, useVocabulary: Bool = true) async throws -> String {
        if usesQwen {
            return try await serial {
                let m = try await self.loadQwen()
                let t0 = Date()
                // The vocabulary goes in as context terms, which biases the decoder toward those spellings.
                let vocab = useVocabulary ? Vocabulary.load() : []
                let text = m.transcribe(audio: samples, sampleRate: 16000, context: vocab.isEmpty ? nil : vocab.joined(separator: " "))
                if ProcessInfo.processInfo.environment["VT_DEBUG"] != nil {
                    print(String(format: "segment %.1fs audio [qwen], decode %.2fs", Double(samples.count) / 16000, Date().timeIntervalSince(t0)), "->", text)
                }
                await self.scheduleUnload()
                return Self.cleanQwen(text)
            }
        }
        return try await serial {
            let k = try await self.loadedKit()
            let t0 = Date()
            var opts = DecodingOptions(task: .transcribe, language: language, temperature: 0,
                                       usePrefillPrompt: true, detectLanguage: false,
                                       skipSpecialTokens: true, withoutTimestamps: true)
            if let tok = k.tokenizer {
                var prompt = ProcessInfo.processInfo.environment["VT_PROMPT"] ?? Self.promptText(language: language, useVocabulary: useVocabulary)
                if !context.isEmpty { prompt += " " + String(context.suffix(120)) }
                // Whisper accepts about 224 prompt tokens; keep the end (newest words, example, context).
                let tokens = tok.encode(text: " " + prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
                opts.promptTokens = Array(tokens.suffix(200))
            }
            let results = try await k.transcribe(audioArray: samples, decodeOptions: opts)
            let text = results.map(\.text).joined(separator: " ")
            if ProcessInfo.processInfo.environment["VT_DEBUG"] != nil {
                print(String(format: "segment %.1fs audio [%@], decode %.2fs", Double(samples.count) / 16000, language, Date().timeIntervalSince(t0)), "->", text)
            }
            await self.scheduleUnload()
            return Self.clean(text)
        }
    }

    func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleUnloadSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func unload() async {
        if let kit { await kit.unloadModels() }
        kit = nil
        qwen?.unload()
        qwen = nil
    }

    /// Vocabulary first, then the example, so truncation drops the oldest words first.
    static func promptText(language: String, useVocabulary: Bool = true) -> String {
        let example = language == "en"
            ? "I think 这个 idea 很好, but the 难度 is higher."
            : "今天的 meeting 很重要。I will send you the report later. 你看一下，然后告诉我。"
        let vocab = useVocabulary ? Vocabulary.load() : []
        return vocab.isEmpty ? example : vocab.joined(separator: ", ") + ". " + example
    }

    /// Punctuation follows the language of the text before it; no spaces between Chinese characters.
    static func format(_ s: String) -> String {
        let han = "\\p{Han}"
        let toFull: [(String, String)] = [(",", "，"), ("?", "？"), ("!", "！"), (":", "："), (";", "；"), (".", "。")]
        let toHalf: [(String, String)] = [("，", ", "), ("？", "? "), ("！", "! "), ("：", ": "), ("；", "; "), ("。", ". ")]
        var t = s
        for (a, b) in toFull {
            t = t.replacingOccurrences(of: "(?<=\(han))\\s*\\\(a)\\s*", with: b, options: .regularExpression)
        }
        for (a, b) in toHalf {
            t = t.replacingOccurrences(of: "(?<=[A-Za-z0-9])\\s*\(a)\\s*(?=[A-Za-z0-9])", with: b, options: .regularExpression)
            t = t.replacingOccurrences(of: "(?<=[A-Za-z0-9])\\s*\(a)\\s*$", with: b.trimmingCharacters(in: .whitespaces), options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "(?<=\(han))\\s+(?=\(han))", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=[A-Za-z])([,?!;:])(?=[A-Za-z])", with: "$1 ", options: .regularExpression)
        // A time or ratio keeps a plain colon with no spaces: 3:30, not "3: 30" or "3：30".
        t = t.replacingOccurrences(of: "(?<=\\d)\\s*[:：]\\s*(?=\\d)", with: ":", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<=[，。？！：；、])\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+(?=[，。？！：；、])", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        // A trailing comma or no punctuation means Whisper stopped mid-sentence; close it.
        if t.hasSuffix("，") { t = String(t.dropLast()) + "。" } else if t.hasSuffix(",") { t = String(t.dropLast()) + "." }
        if let last = t.unicodeScalars.last, CharacterSet.letters.union(.decimalDigits).contains(last) {
            t += String(last).range(of: "\\p{Han}", options: .regularExpression) != nil ? "。" : "."
        }
        return t
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? t
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
