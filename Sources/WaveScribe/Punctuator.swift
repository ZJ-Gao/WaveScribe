import CSherpaPunct
import Darwin
import Foundation

/// Re-punctuates the finished text with a CT-Transformer punctuation model (sherpa-onnx, Chinese and English).
/// Whisper puts a period at most pauses, even mid-sentence; this model decides from the whole text instead.
/// It only places punctuation: if its output differs from the input in anything but punctuation, the input is kept.
/// The library is loaded with dlopen, so without it (or before the model is downloaded) text passes through unchanged.
actor Punctuator {
    static let shared = Punctuator()
    static let modelName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
    static let modelURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/\(modelName).tar.bz2")!
    static let idleUnloadSeconds: UInt64 = 60

    private var handle: UnsafeMutableRawPointer?
    private var punct: UnsafeRawPointer?
    private var addPunct: SherpaAddPunctFn?
    private var freeText: SherpaFreeTextFn?
    private var destroy: SherpaDestroyPunctFn?
    private var unloadTask: Task<Void, Never>?
    private var downloading = false

    static var modelFile: URL {
        Paths.modelsDir.appendingPathComponent("punct/\(modelName)/model.int8.onnx")
    }

    /// The app bundle's Frameworks folder, or, when run from .build during development,
    /// the project's Vendor folder found by walking up from the executable.
    static var libraryDirs: [URL] {
        var dirs: [URL] = []
        if let f = Bundle.main.privateFrameworksURL { dirs.append(f) }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            let lib = d.appendingPathComponent("Vendor/sherpa-onnx/lib")
            if FileManager.default.fileExists(atPath: lib.path) { dirs.append(lib); break }
            dir = d.deletingLastPathComponent()
        }
        return dirs
    }

    /// Download the model once (75 MB) in the background; until then text is left as Whisper punctuated it.
    func ensureDownloaded() async {
        if FileManager.default.fileExists(atPath: Self.modelFile.path) || downloading { return }
        downloading = true
        defer { downloading = false }
        let dir = Paths.modelsDir.appendingPathComponent("punct", isDirectory: true)
        do {
            // Extract into a scratch folder and move it in whole, so a half-extracted model is never loaded.
            let staging = dir.appendingPathComponent(".extracting", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let (tmp, _) = try await URLSession.shared.download(from: Self.modelURL)
            defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: staging) }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xjf", tmp.path, "-C", staging.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.moveItem(at: staging.appendingPathComponent(Self.modelName),
                                             to: dir.appendingPathComponent(Self.modelName))
        } catch {
            print("punctuation model download failed:", error)
        }
    }

    /// Load ahead of use (about 0.1 s), e.g. when recording starts.
    func preload() {
        unloadTask?.cancel()
        _ = load()
    }

    private func load() -> Bool {
        if punct != nil { return true }
        guard FileManager.default.fileExists(atPath: Self.modelFile.path) else { return false }
        if handle == nil {
            for dir in Self.libraryDirs {
                if let h = dlopen(dir.appendingPathComponent("libsherpa-onnx-c-api.dylib").path, RTLD_NOW | RTLD_LOCAL) {
                    handle = h
                    if ProcessInfo.processInfo.environment["VT_DEBUG"] != nil { print("punctuation library from", dir.path) }
                    break
                }
            }
        }
        guard let handle,
              let c = dlsym(handle, "SherpaOnnxCreateOfflinePunctuation"),
              let a = dlsym(handle, "SherpaOfflinePunctuationAddPunct"),
              let f = dlsym(handle, "SherpaOfflinePunctuationFreeText"),
              let d = dlsym(handle, "SherpaOnnxDestroyOfflinePunctuation") else { return false }
        let create = unsafeBitCast(c, to: SherpaCreatePunctFn.self)
        addPunct = unsafeBitCast(a, to: SherpaAddPunctFn.self)
        freeText = unsafeBitCast(f, to: SherpaFreeTextFn.self)
        destroy = unsafeBitCast(d, to: SherpaDestroyPunctFn.self)
        punct = Self.modelFile.path.withCString { model in
            "cpu".withCString { provider in
                var config = SherpaOnnxOfflinePunctuationConfig(
                    model: SherpaOnnxOfflinePunctuationModelConfig(ct_transformer: model, num_threads: 2, debug: 0, provider: provider))
                return create(&config)
            }
        }
        return punct != nil
    }

    /// Returns `text` with its punctuation replaced by the model's, or `text` unchanged if that is not possible.
    func punctuate(_ text: String) -> String {
        guard !text.isEmpty, load(), let punct, let addPunct, let freeText else { return text }
        defer { scheduleUnload() }
        let bare = Self.strip(text)
        guard let out = bare.withCString({ addPunct(punct, $0) }) else { return text }
        let result = String(cString: out)
        freeText(out)
        return Self.words(result) == Self.words(text) ? Self.restoreNumbers(result, from: bare) : text
    }

    /// The model splits numbers such as 3.30 or 3:30 when it punctuates ("3 . 30"); put each one back as written.
    static func restoreNumbers(_ out: String, from input: String) -> String {
        let number = try! NSRegularExpression(pattern: #"\d+(?:[.,:：]\d+)+"#)
        var result = out
        var searchFrom = result.startIndex
        for m in number.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
            let token = String(input[Range(m.range, in: input)!])
            let groups = token.split(whereSeparator: { !$0.isNumber }).map(String.init)
            let loose = groups.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"\s*[^\p{L}\p{N}\s]?\s*"#)
            guard let r = result.range(of: loose, options: .regularExpression, range: searchFrom..<result.endIndex) else { continue }
            result.replaceSubrange(r, with: token)
            searchFrom = result.index(r.lowerBound, offsetBy: token.count)
        }
        return result
    }

    /// Remove sentence punctuation (not the point, comma or colon inside a number such as 3.5, 30,000 or 3:30)
    /// and the spaces it leaves between Chinese.
    static func strip(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"[，。？！、；?!;…]+|(?<!\d)[.,:：]|[.,:：](?!\d)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<=\p{Han})\s+(?=\p{Han})"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Letters and digits only, for checking that the model changed nothing but punctuation.
    static func words(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleUnloadSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func unload() {
        if let punct, let destroy { destroy(punct) }
        punct = nil
    }
}
