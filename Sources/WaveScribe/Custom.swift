import Foundation

/// A user-confirmed text replacement, applied after transcription. Include some surrounding
/// characters in `wrong` (e.g. "清洗之间") so a word that is sometimes right is not replaced everywhere.
struct Rule: Codable, Identifiable, Equatable {
    var id = UUID()
    var wrong: String
    var right: String
    var enabled = true
}

enum Rules {
    static let file = Paths.dataDir.appendingPathComponent("rules.json")

    static func load() -> [Rule] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Rule].self, from: d)) ?? []
    }

    static func save(_ rules: [Rule]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(rules) { try? d.write(to: file) }
    }

    static func apply(_ s: String, rules: [Rule] = load()) -> String {
        var t = s
        for r in rules where r.enabled && !r.wrong.isEmpty { t = t.replacingOccurrences(of: r.wrong, with: r.right) }
        return t
    }
}

extension Vocabulary {
    static func save(_ words: [String]) {
        let header = "# 每行一个常用词，转写时会提示给模型。以 # 开头的行会被忽略。\n"
        try? (header + words.joined(separator: "\n") + "\n").write(to: Paths.vocabulary, atomically: true, encoding: .utf8)
    }
}

/// One edit the user made to a transcript: what the model wrote vs. what the user wanted.
struct Suggestion: Hashable {
    let wrong: String        // word-level, for display
    let right: String        // word-level, added to the vocabulary
    let ruleWrong: String    // with one more character of context, for a replacement rule
    let ruleRight: String
}

enum Suggestions {
    /// Character-level diff of model output vs. edited text, grouped into changed spans.
    /// Short Chinese spans are widened with neighbouring characters so they read as words
    /// ("冷→老" becomes "冷话→老话"); English spans are widened to whole words.
    static func from(raw: String, edited: String) -> [Suggestion] {
        let a = Array(raw), b = Array(edited)
        guard a != b, a.count * b.count < 2_000_000 else { return [] }
        // LCS table.
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        // Walk the table and collect spans [i0,i1) in a and [j0,j1) in b that differ.
        var spans: [(Int, Int, Int, Int)] = []
        var i = 0, j = 0
        var open: (Int, Int)?
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                if let o = open { spans.append((o.0, i, o.1, j)); open = nil }
                i += 1; j += 1
            } else {
                if open == nil { open = (i, j) }
                if j < m && (i == n || dp[i][j + 1] >= dp[i + 1][j]) { j += 1 } else { i += 1 }
            }
        }
        if let o = open { spans.append((o.0, n, o.1, m)) }

        var out: [Suggestion] = []
        for (i0, i1, j0, j1) in spans {
            var (ai0, ai1, bj0, bj1) = (i0, i1, j0, j1)
            let isLatin: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
            // Widen English spans to whole words.
            while ai0 > 0, bj0 > 0, isLatin(a[ai0 - 1]), a[ai0 - 1] == b[bj0 - 1] { ai0 -= 1; bj0 -= 1 }
            while ai1 < n, bj1 < m, isLatin(a[ai1]), a[ai1] == b[bj1] { ai1 += 1; bj1 += 1 }
            // Widen short Chinese spans: one changed character gets a neighbour on each side,
            // otherwise make sure the corrected side has at least two characters.
            let isHan: (Character) -> Bool = { $0.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false }
            func growRight() -> Bool {
                guard bj1 < m, ai1 < n, isHan(b[bj1]), a[ai1] == b[bj1] else { return false }
                ai1 += 1; bj1 += 1; return true
            }
            func growLeft() -> Bool {
                guard bj0 > 0, ai0 > 0, isHan(b[bj0 - 1]), a[ai0 - 1] == b[bj0 - 1] else { return false }
                ai0 -= 1; bj0 -= 1; return true
            }
            if bj1 - bj0 == 1 && ai1 - ai0 == 1 { _ = growLeft(); _ = growRight() }
            while bj1 - bj0 < 2 { if !growRight() && !growLeft() { break } }
            let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            let w = String(a[ai0..<ai1]).trimmingCharacters(in: trim)
            let r = String(b[bj0..<bj1]).trimmingCharacters(in: trim)
            guard !r.isEmpty, w != r, r.count <= 20 else { continue }
            // Rule context: one more character, preferring the right side.
            if !growRight() { _ = growLeft() }
            let rw = String(a[ai0..<ai1]).trimmingCharacters(in: trim)
            let rr = String(b[bj0..<bj1]).trimmingCharacters(in: trim)
            out.append(Suggestion(wrong: w, right: r, ruleWrong: rw, ruleRight: rr))
        }
        var seen = Set<Suggestion>()
        return out.filter { seen.insert($0).inserted }
    }
}

/// Vocabulary and rules, editable from the UI.
@MainActor
final class CustomStore: ObservableObject {
    static let shared = CustomStore()
    @Published private(set) var words: [String] = Vocabulary.load()
    @Published private(set) var rules: [Rule] = Rules.load()

    /// Files can also be edited outside the app; re-read them before showing or changing.
    func reload() { words = Vocabulary.load(); rules = Rules.load() }

    func addWord(_ w: String) {
        reload()
        let w = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !words.contains(w) else { return }
        words.append(w); Vocabulary.save(words)
    }
    func removeWord(_ w: String) { words.removeAll { $0 == w }; Vocabulary.save(words) }

    func addRule(wrong: String, right: String) {
        reload()
        let w = wrong.trimmingCharacters(in: .whitespaces), r = right.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, w != r, !rules.contains(where: { $0.wrong == w }) else { return }
        rules.append(Rule(wrong: w, right: r)); Rules.save(rules)
    }
    func removeRule(_ id: UUID) { rules.removeAll { $0.id == id }; Rules.save(rules) }
    func toggleRule(_ id: UUID) {
        if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].enabled.toggle(); Rules.save(rules) }
    }

    func hasWord(_ w: String) -> Bool { words.contains(w) }
    func hasRule(_ wrong: String) -> Bool { rules.contains { $0.wrong == wrong } }
}
