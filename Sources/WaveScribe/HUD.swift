import AppKit
import SwiftUI

/// Small floating indicator at the bottom of the screen while recording and transcribing.
/// It never takes focus or clicks, so the cursor stays where the text will be pasted.
@MainActor
final class RecordingHUD {
    final class Model: ObservableObject {
        @Published var transcribing = false
        @Published var message: String?
        @Published var elapsed: TimeInterval = 0
        @Published var levels: [CGFloat] = Array(repeating: 0.1, count: 12)
    }

    private let panel: NSPanel
    private let model = Model()
    private var timer: Timer?
    private var start = Date()
    private var peak: Float = 0.001
    private let level: () -> Float

    init(level: @escaping () -> Float) {
        self.level = level
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func showRecording() {
        model.message = nil
        model.transcribing = false
        model.elapsed = 0
        peak = 0.001
        start = Date()
        place()
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func showTranscribing() {
        timer?.invalidate(); timer = nil
        model.message = nil
        model.transcribing = true
        if !panel.isVisible { place(); panel.orderFrontRegardless() }
    }

    /// Replace the indicator with a short warning, then fade it out after a few seconds.
    func showMessage(_ text: String) {
        timer?.invalidate(); timer = nil
        model.message = text
        if !panel.isVisible { place(); panel.orderFrontRegardless() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
    }

    private func tick() {
        model.elapsed = Date().timeIntervalSince(start)
        let l = level()
        // Scale against the loudest recent input, so a quiet microphone still shows movement.
        peak = max(l, peak * 0.995, 0.001)
        let v = CGFloat(min(1, l / peak))
        model.levels = [max(0.1, v)] + Array(model.levels.dropLast())   // newest on the left, flowing right
    }

    /// English labels are longer than Chinese ones, so the pill is wider in English.
    static var width: CGFloat { Settings.isChinese ? 270 : 330 }

    /// Show the pill for two seconds where it will appear, after the position is changed in Preferences.
    func showPreview() {
        model.message = nil
        model.transcribing = false
        model.elapsed = 0
        place()
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    /// On the screen with the mouse, at the position chosen in Preferences (bottom centre by default).
    private func place() {
        panel.setContentSize(NSSize(width: Self.width, height: 44))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let pos = HUDPosition.current
        let margin: CGFloat = 24
        let w = panel.frame.width, h = panel.frame.height
        let x = [f.minX + margin, f.midX - w / 2, f.maxX - w - margin][pos.column]
        let y = [f.maxY - h - margin, f.midY - h / 2, f.minY + margin][pos.row]
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct HUDView: View {
    @ObservedObject var model: RecordingHUD.Model
    @State private var pulse = false
    @AppStorage("muyu") private var muyu = true

    var body: some View {
        HStack(spacing: 10) {
            if let message = model.message {
                Image(systemName: "mic.slash.fill").foregroundStyle(.yellow)
                Text(message).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            } else if model.transcribing {
                if muyu { Muyu() } else { ProgressView().controlSize(.small).tint(.white) }
                Text(L("转写中…", "Transcribing…")).foregroundStyle(.white).lineLimit(1).fixedSize()
            } else {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                Text(L("正在录音", "Recording")).foregroundStyle(.white).lineLimit(1).fixedSize()
                HStack(spacing: 2) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { _, v in
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: 3, height: 4 + 16 * v)
                    }
                }
                .frame(height: 20)
                Text(String(format: "%d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.8))
                Text(L("esc 取消", "esc to cancel")).font(.system(size: 11)).lineLimit(1).fixedSize().foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(width: RecordingHUD.width, height: 44)
        .background(Capsule().fill(Color.black.opacity(0.78)))
    }
}

/// While transcribing: a wooden fish struck once a second, like a slow chant.
private struct Muyu: View {
    @State private var struck = false
    var body: some View {
        MuyuIcon(struck: struck)
            .task {
                while !Task.isCancelled {
                    withAnimation(.easeIn(duration: 0.08)) { struck = true }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation(.easeOut(duration: 0.35)) { struck = false }
                    try? await Task.sleep(nanoseconds: 880_000_000)
                }
            }
    }
}

/// Wooden fish silhouette in a 100 x 75 design space.
private struct MuyuBody: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 100, sy = r.height / 75
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var path = Path()
        path.move(to: p(5, 57))                                              // nub, lower left
        path.addCurve(to: p(62, 5), control1: p(22, 36), control2: p(42, 8))   // near-straight rising edge
        path.addCurve(to: p(97, 40), control1: p(84, 3), control2: p(97, 22))  // peak right of centre
        path.addCurve(to: p(64, 72), control1: p(97, 60), control2: p(83, 72)) // round right bulge
        path.addCurve(to: p(17, 66), control1: p(44, 72), control2: p(27, 70))
        path.addCurve(to: p(5, 57), control1: p(10, 63), control2: p(4, 60))
        path.closeSubpath()
        return path
    }
}

private struct MuyuSlit: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 100, sy = r.height / 75
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var path = Path()
        path.move(to: p(36, 49))                                             // rounded inner end
        path.addCurve(to: p(102, 32), control1: p(54, 38), control2: p(80, 32))
        path.addLine(to: p(102, 39))
        path.addCurve(to: p(45, 55), control1: p(80, 39), control2: p(60, 47))
        path.addCurve(to: p(36, 49), control1: p(39, 59), control2: p(32, 54))
        path.closeSubpath()
        return path
    }
}

private struct MuyuIcon: View {
    var struck: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                MuyuBody().fill(Color.white)
                MuyuSlit().fill(Color.black).blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: 30, height: 23)
            .scaleEffect(struck ? 0.9 : 1, anchor: .bottom)
            .offset(x: 0, y: 9)
            HStack(spacing: -1) {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Capsule().fill(Color.white).frame(width: 14, height: 2)
            }
            .frame(width: 19, height: 6)
            .rotationEffect(.degrees(struck ? -5 : 35), anchor: .trailing)
            .offset(x: 14, y: 7)
        }
        .frame(width: 34, height: 32, alignment: .topLeading)
    }
}


/// Where the recording pill appears: one cell of a 3 x 3 grid over the screen. Stored as "row,column".
struct HUDPosition: Equatable {
    static let key = "hudPosition"
    static let bottomCenter = HUDPosition(row: 2, column: 1)
    var row: Int     // 0 top, 1 middle, 2 bottom
    var column: Int  // 0 left, 1 centre, 2 right

    var raw: String { "\(row),\(column)" }
    init(row: Int, column: Int) { self.row = row; self.column = column }
    init?(raw: String) {
        let p = raw.split(separator: ",").compactMap { Int($0) }
        guard p.count == 2, (0...2).contains(p[0]), (0...2).contains(p[1]) else { return nil }
        self.init(row: p[0], column: p[1])
    }
    static var current: HUDPosition { UserDefaults.standard.string(forKey: key).flatMap(HUDPosition.init(raw:)) ?? .bottomCenter }
}
