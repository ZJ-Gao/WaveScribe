import AppKit
import SwiftUI

struct TestView: View {
    @ObservedObject var state: AppState
    @ObservedObject var history = HistoryStore.shared
    @ObservedObject var settings = Settings.shared
    @State private var showCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if history.entries.isEmpty {
                Spacer()
                Text("按 \(Settings.shared.shortcutText) 开始说话，再按一次结束，Esc 取消。\n在这个窗口里说，文字会变成下面的一张卡片，可以直接编辑、复制。\n在别的 App 里说，文字会贴到光标处，这里也会留一份。\n所有记录只保留 24 小时。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(history.entries) { e in
                                RecordCard(entry: e, isNew: e.id == state.newestInWindow).id(e.id)
                            }
                        }
                    }
                    .onChange(of: state.newestInWindow) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 480)
        .sheet(isPresented: $showCustom) { CustomView(state: state) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            recordButton
            statusLabel
            Spacer()
            Button { showCustom = true } label: { Label("词表与规则", systemImage: "character.book.closed") }
            Text("模型：\(state.modelLoaded ? "已加载" : "未加载")").foregroundStyle(.secondary)
            Text(String(format: "内存 %.0f MB", state.memoryMB)).monospacedDigit().foregroundStyle(.secondary)
            if !state.accessibilityOK {
                Button("开启辅助功能权限") { Inserter.requestAccessibility() }
            }
        }
        .font(.callout)
    }

    private var recordButton: some View {
        let recording = state.status == .recording
        let busy: Bool = {
            switch state.status {
            case .transcribing, .warming, .downloading: return true
            default: return false
            }
        }()
        return Button { state.toggle() } label: {
            Label(recording ? "停止" : "录音", systemImage: recording ? "stop.fill" : "mic.fill")
                .frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(recording ? .red : .accentColor)
        .controlSize(.large)
        .disabled(busy)
        .help("也可以用快捷键 \(Settings.shared.shortcutText)")
    }

    @ViewBuilder private var statusLabel: some View {
        switch state.status {
        case .idle: Label("就绪", systemImage: "mic")
        case .recording: Label("录音中…", systemImage: "mic.fill").foregroundStyle(.red)
        case .transcribing: Label("转写中…", systemImage: "waveform")
        case .warming: Label("首次准备模型（只需一次，约1到2分钟）…", systemImage: "hourglass")
        case .downloading(let p): Label(String(format: "下载模型 %.0f%%", p * 100), systemImage: "arrow.down.circle")
        case .error(let e): Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

struct RecordCard: View {
    let entry: HistoryEntry
    let isNew: Bool
    @State private var text = ""
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.date, format: .dateTime.hour().minute())
                if !entry.target.isEmpty && entry.target != "window" {
                    Text("→ \(entry.target == "popup" ? "弹窗" : entry.target)")
                }
                Text(String(format: "录音 %.1f 秒 · 转写 %.2f 秒", entry.audioSeconds, entry.latency))
                Spacer()
                if text != entry.raw { Text("已修改").foregroundStyle(.blue) }
            }
            .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: text) { _, t in HistoryStore.shared.updateText(entry.id, t) }
            if text != entry.raw { SuggestionChips(raw: entry.raw, edited: text) }
            HStack {
                if text != entry.raw {
                    Text("原始：\(entry.raw)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(entry.raw)
                }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .confirmationDialog("删除这条记录？", isPresented: $confirmDelete) {
                        Button("删除", role: .destructive) { HistoryStore.shared.delete(entry.id) }
                    }
                Button(copied ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isNew ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
        .onAppear { text = entry.text }
    }
}

/// Small floating window shown when there is no text field to paste into.
enum ResultPanel {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable],
                        backing: .buffered, defer: false)
        p.title = "转写结果"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: PanelView(text: text) { p.close() })
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 400, y: f.maxY - 180))
        }
        p.orderFrontRegardless()
        panel = p
    }

    struct PanelView: View {
        let text: String
        let close: () -> Void
        @State private var copied = false
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Spacer()
                    Button(copied ? "已复制" : "复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { close() }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("关闭", action: close)
                }
            }
            .padding(12)
        }
    }
}

/// Turns the user's edits on a card into one-click vocabulary words or replacement rules.
struct SuggestionChips: View {
    let raw: String
    let edited: String
    @ObservedObject var custom = CustomStore.shared

    var body: some View {
        let items = Suggestions.from(raw: raw, edited: edited)
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("学习：").font(.caption).foregroundStyle(.secondary)
                    ForEach(items, id: \.self) { sug in
                        let done = custom.hasWord(sug.right) || custom.hasRule(sug.ruleWrong)
                        Menu {
                            Button("把「\(sug.right)」加入词表（推荐）") { custom.addWord(sug.right) }
                            if !sug.wrong.isEmpty && sug.ruleWrong.count >= 2 {
                                Button("添加替换规则：「\(sug.ruleWrong)」→「\(sug.ruleRight)」") { custom.addRule(wrong: sug.ruleWrong, right: sug.ruleRight) }
                            }
                        } label: {
                            Text(sug.wrong.isEmpty ? "+ \(sug.right)" : "\(sug.wrong) → \(sug.right)")
                                .font(.caption)
                                .foregroundStyle(done ? .secondary : .primary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(done ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.12)))
                    }
                }
            }
        }
    }
}

struct CustomView: View {
    @ObservedObject var state: AppState
    @ObservedObject var custom = CustomStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newWord = ""
    @State private var newWrong = ""
    @State private var newRight = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("词表与规则").font(.title3.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            GroupBox("词表：提示模型这些词可能出现，最终写法仍由发音和上下文决定") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("新词，比如 亲戚、WaveScribe", text: $newWord).onSubmit(addWord)
                        Button("添加", action: addWord)
                    }
                    if custom.words.isEmpty { Text("还没有词").foregroundStyle(.secondary).font(.caption) }
                    FlowList(items: custom.words) { w in
                        HStack(spacing: 3) {
                            Text(w)
                            Button { custom.removeWord(w) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }.padding(4)
            }
            GroupBox("替换规则：转写后把左边的文字直接换成右边，带上前后文更安全（如「清洗之间」）") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("听错的写法", text: $newWrong)
                        Image(systemName: "arrow.right")
                        TextField("正确写法", text: $newRight).onSubmit(addRule)
                        Button("添加", action: addRule)
                    }
                    if custom.rules.isEmpty { Text("还没有规则").foregroundStyle(.secondary).font(.caption) }
                    ForEach(custom.rules) { r in
                        HStack {
                            Toggle("", isOn: Binding(get: { r.enabled }, set: { _ in custom.toggleRule(r.id) })).labelsHidden()
                            Text(r.wrong); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(r.right)
                            Spacer()
                            Button { custom.removeRule(r.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .foregroundStyle(r.enabled ? .primary : .secondary)
                    }
                }.padding(4)
            }
            GroupBox("验证：用你存下的录音重跑一遍，对比加词表和规则前后的错字数") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button(state.validating ? "验证中 \(state.validationProgress)…" : "开始验证") { state.validate() }
                            .disabled(state.validating)
                        if !state.validation.isEmpty && !state.validating {
                            let b = state.validation.map(\.errorsBefore).reduce(0, +)
                            let a = state.validation.map(\.errorsAfter).reduce(0, +)
                            let n = max(1, state.validation.map(\.length).reduce(0, +))
                            Text(String(format: "错字 %d → %d（%.1f%% → %.1f%%）", b, a, 100 * Double(b) / Double(n), 100 * Double(a) / Double(n)))
                                .foregroundStyle(a < b ? .green : a > b ? .red : .secondary)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(state.validation.filter { $0.errorsBefore != $0.errorsAfter }) { r in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(r.audio)：错字 \(r.errorsBefore) → \(r.errorsAfter)")
                                        .font(.caption.bold()).foregroundStyle(r.errorsAfter < r.errorsBefore ? .green : .red)
                                    Text("之前：\(r.before)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text("之后：\(r.after)").font(.caption).lineLimit(2)
                                }
                            }
                            if !state.validation.isEmpty && !state.validating && state.validation.allSatisfy({ $0.errorsBefore == $0.errorsAfter }) {
                                Text("所有录音的结果都没有变化").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxHeight: 160)
                }.padding(4)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { custom.reload() }
    }

    private func addWord() { custom.addWord(newWord); newWord = "" }
    private func addRule() { custom.addRule(wrong: newWrong, right: newRight); newWrong = ""; newRight = "" }
}

/// Simple wrapping layout for chips.
struct FlowList<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    var body: some View { Flow(spacing: 6) { ForEach(items, id: \.self) { content($0) } } }
}

struct Flow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
