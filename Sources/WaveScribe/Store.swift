import Foundation

enum Paths {
    /// History, recordings, vocabulary and rules: ~/Library/Application Support/WaveScribe/Data,
    /// or the folder in VT_DATA_DIR (handy for testing against a copy).
    static let dataDir: URL = {
        let url = ProcessInfo.processInfo.environment["VT_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WaveScribe/Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let audioDir: URL = {
        let url = dataDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let modelsDir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaveScribe/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let history = dataDir.appendingPathComponent("history.json")
    static let corrections = dataDir.appendingPathComponent("corrections.jsonl")
    static let vocabulary = dataDir.appendingPathComponent("vocabulary.txt")
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var raw: String          // what the model produced
    var text: String         // current text, after the user's edits
    var audioFile: String?
    var audioSeconds: Double = 0
    var latency: Double = 0
    var target: String = ""  // where it went: "window", an app name, or "popup"

    init(date: Date, raw: String, audioFile: String?, audioSeconds: Double, latency: Double, target: String) {
        self.date = date; self.raw = raw; self.text = raw; self.audioFile = audioFile
        self.audioSeconds = audioSeconds; self.latency = latency; self.target = target
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        text = try c.decode(String.self, forKey: .text)
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? text
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile)
        audioSeconds = try c.decodeIfPresent(Double.self, forKey: .audioSeconds) ?? 0
        latency = try c.decodeIfPresent(Double.self, forKey: .latency) ?? 0
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
    }
}

/// Dictation history kept for 24 hours. Newest first. Older recordings are kept or deleted per the
/// "录音保留" preference (see CorrectionLog.prune).
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []
    private let maxAge: TimeInterval = 24 * 3600
    private var timer: Timer?
    private var pendingSave: DispatchWorkItem?

    init() {
        if let data = try? Data(contentsOf: Paths.history) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            entries = ((try? dec.decode([HistoryEntry].self, from: data)) ?? []).sorted { $0.date > $1.date }
        }
        purge()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in HistoryStore.shared.purge() }
        }
    }

    @discardableResult
    func add(_ e: HistoryEntry) -> HistoryEntry {
        entries.insert(e, at: 0)
        save()
        CorrectionLog.upsert(e)
        return e
    }

    /// Called on every keystroke; writes to disk after a short pause.
    func updateText(_ id: UUID, _ text: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].text != text else { return }
        entries[i].text = text
        let e = entries[i]
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(); CorrectionLog.upsert(e) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func delete(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries.remove(at: i)
        if let f = e.audioFile { try? FileManager.default.removeItem(at: Paths.audioDir.appendingPathComponent(f)) }
        CorrectionLog.remove(id)
        save()
    }

    func purge() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        CorrectionLog.prune(before: cutoff, keeping: Settings.currentRetention)
        let protected = CorrectionLog.audioFiles()
        for e in entries where e.date < cutoff {
            if let f = e.audioFile, !protected.contains(f) {
                try? FileManager.default.removeItem(at: Paths.audioDir.appendingPathComponent(f))
            }
        }
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        if entries.count != before { save() }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(entries) { try? data.write(to: Paths.history) }
    }
}

enum Vocabulary {
    /// One term per line. Fed to Whisper as a prompt to bias recognition.
    static func load() -> [String] {
        guard let s = try? String(contentsOf: Paths.vocabulary, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// Log of model output vs. the user's final text, one JSON line per dictation. Rows and their audio that
/// outlive the 24-hour history serve as test answers for comparing models; how many are kept is a preference.
enum CorrectionLog {
    /// Drop rows older than `cutoff` (and their audio) unless the retention setting keeps them.
    static func prune(before cutoff: Date, keeping retention: Settings.Retention) {
        if retention == .all { return }
        let iso = ISO8601DateFormatter()
        let rows = load()
        let kept = rows.filter { row in
            guard let t = (row["time"] as? String).flatMap(iso.date(from:)), t < cutoff else { return true }
            return retention == .edited && (row["changed"] as? Bool) == true
        }
        guard kept.count != rows.count else { return }
        let keptAudio = Set(kept.compactMap { $0["audio"] as? String })
        for row in rows {
            if let f = row["audio"] as? String, !f.isEmpty, !keptAudio.contains(f) {
                try? FileManager.default.removeItem(at: Paths.audioDir.appendingPathComponent(f))
            }
        }
        write(kept)
    }

    private static func load() -> [[String: Any]] {
        guard let s = try? String(contentsOf: Paths.corrections, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private static func write(_ rows: [[String: Any]]) {
        let lines = rows.compactMap { row -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: Paths.corrections, atomically: true, encoding: .utf8)
    }

    static func upsert(_ e: HistoryEntry) {
        var rows = load()
        let row: [String: Any] = [
            "id": e.id.uuidString,
            "time": ISO8601DateFormatter().string(from: e.date),
            "model": Settings.currentEngine == .qwen ? Transcriber.qwenModelId : Transcriber.modelName,
            "raw": e.raw,
            "corrected": e.text,
            "changed": e.raw != e.text,
            "audio": e.audioFile ?? "",
            "audio_seconds": (e.audioSeconds * 10).rounded() / 10,
            "latency_seconds": (e.latency * 100).rounded() / 100,
            "target": e.target,
        ]
        if let i = rows.firstIndex(where: { ($0["id"] as? String) == e.id.uuidString }) { rows[i] = row } else { rows.append(row) }
        write(rows)
    }

    static func remove(_ id: UUID) {
        write(load().filter { ($0["id"] as? String) != id.uuidString })
    }

    /// Recordings with the user's final text, newest version per audio file.
    static func references() -> [(audio: String, reference: String)] {
        var byAudio: [String: String] = [:]
        var order: [String] = []
        for row in load() {
            guard let a = row["audio"] as? String, !a.isEmpty, let t = row["corrected"] as? String,
                  FileManager.default.fileExists(atPath: Paths.audioDir.appendingPathComponent(a).path) else { continue }
            if byAudio[a] == nil { order.append(a) }
            byAudio[a] = t
        }
        return order.map { ($0, byAudio[$0]!) }
    }

    static func audioFiles() -> Set<String> {
        Set(load().compactMap { $0["audio"] as? String }.filter { !$0.isEmpty })
    }
}

struct ValidationRow: Identifiable {
    var id: String { audio }
    let audio: String
    let reference: String
    let before: String
    let after: String
    let errorsBefore: Int
    let errorsAfter: Int
    let length: Int
}

/// Character error count, ignoring punctuation, spaces and case.
enum CER {
    static func normalize(_ s: String) -> [Character] {
        Array(s.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    static func errors(_ hyp: String, _ ref: String) -> Int {
        let a = normalize(hyp), b = normalize(ref)
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
