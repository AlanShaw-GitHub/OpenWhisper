import SwiftUI
import AppKit

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TransparentHUDHostingView: NSHostingView<RecordingHUD> {
    override var isOpaque: Bool { false }
}

@MainActor
final class RecordingHUDController {
    private let panel: NSPanel
    private let state: AppState
    private let hosting: TransparentHUDHostingView
    private var hideTask: Task<Void, Never>?
    init(state: AppState) {
        self.state = state
        hosting = TransparentHUDHostingView(rootView: RecordingHUD(state: state, preview: false))
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel = NonActivatingPanel(contentRect: NSRect(x: 0, y: 0, width: RecordingHUD.size.width, height: RecordingHUD.size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.contentView = hosting
    }
    func show(preview: Bool = false) {
        hideTask?.cancel()
        hosting.rootView = RecordingHUD(state: state, preview: preview)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        // Extra transparent space keeps the capsule's blur away from the rectangular window edge.
        // Compensate below so the visible controls stay at their original screen position.
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 6))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
    }
    func hide(after seconds: Double = 0) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, let self else { return }
            // Wait for the fade to finish before taking the panel off screen; `show` cancels this task and resets alpha.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.12; self.panel.animator().alphaValue = 0
                }, completionHandler: { continuation.resume() })
            }
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }
}

struct RecordingHUD: View {
    let state: AppState
    let preview: Bool
    /// Room above the controls for three lines of live text; the transparent rest of the panel lets clicks through.
    static let size = CGSize(width: 680, height: 240)
    var body: some View {
        VStack(spacing: 8) {
            if let liveText { liveTextBubble(liveText) }
            HStack(spacing: 8) {
                Button { state.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20).background(.white.opacity(0.20), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel(L("取消录音"))
                TimelineView(.animation(minimumInterval: 0.06, paused: !state.phase.active && !preview)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 2.2) {
                        ForEach(0..<11, id: \.self) { index in
                            Capsule().fill(.white.opacity(0.96))
                                .frame(width: 2, height: height(index: index, time: time))
                        }
                    }.frame(width: 46, height: 16)
                }.accessibilityLabel(state.phase == .processing ? L("正在转写") : L("录音音量"))
                Button { state.stop() } label: {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black).frame(width: 20, height: 20).background(.white, in: Circle())
                }.buttonStyle(.plain).disabled(!preview && !state.canStopRecording)
                    .accessibilityLabel(L("停止录音并转写"))
            }
            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 5)
            .modifier(HUDSurface(interactive: true))
            Text(preview ? "\(L("正在录音")) · 00:04" : state.hudNotice.text ?? "\(status) · \(state.timeLabel)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .modifier(HUDSurface(interactive: false))
        }
        .modifier(HUDGroup())
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
        .background(Color.clear)
    }
    /// Streaming mode: what has been recognised so far, its latest part when it no longer fits.
    private var liveText: String? {
        guard preview || (state.hudShowsTranscript && state.phase.active), !state.transcript.isEmpty else { return nil }
        let limit = 120
        return state.transcript.count > limit ? "…" + state.transcript.suffix(limit) : state.transcript
    }
    private func liveTextBubble(_ text: String) -> some View {
        // The surface hugs the text; only the outer, invisible frame caps how wide a line may grow before it wraps.
        Text(text)
            .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.95))
            .lineLimit(3).multilineTextAlignment(.leading)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .modifier(HUDSurface(interactive: false, shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
            .frame(maxWidth: 616)
            .accessibilityLabel(L("实时转写"))
    }
    private var status: String {
        // Audio only starts flowing 0.5–1 s after the engine starts; say so instead of inviting speech that would be lost.
        if (state.phase == .connecting || state.phase == .recording) && !state.microphoneLive { return L("正在启动麦克风") }
        if state.phase == .connecting { return L("正在录音") }
        if state.phase == .success && state.copiedToClipboard { return L("已复制到剪贴板") }
        return state.phase.title
    }
    private var icon: String {
        if preview { return "checkmark" }
        switch state.phase { case .failed: return "exclamationmark"; case .processing: return "ellipsis"; default: return "checkmark" }
    }
    private func height(index: Int, time: Double) -> CGFloat {
        if !preview && !state.phase.active { return state.phase == .success ? 7 : 4 }
        let wave = (sin(time * 5 + Double(index) * 0.65) + 1) / 2
        let envelope = 0.4 + 0.6 * sin(Double(index + 1) / 12 * .pi)
        let amplitude = preview || !state.canStopRecording ? 0.5 : state.level
        return 3 + 12 * amplitude * envelope * (0.3 + 0.7 * wave)
    }
}

/// The capsules float over arbitrary content, so they stay near-black on every system: a solid dark
/// fill carries legibility and Liquid Glass (macOS 26+) only adds the edge highlight and press feedback.
private struct HUDSurface<SurfaceShape: InsettableShape>: ViewModifier {
    let interactive: Bool
    let shape: SurfaceShape
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            let glass = Glass.regular.tint(Color.black.opacity(0.9))
            content
                .background(shape.fill(Color(white: 0.06).opacity(0.78)))
                .glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            content
                .background { shape.fill(Color(white: 0.045)).shadow(color: .black.opacity(0.20), radius: 6, y: 2) }
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
    }
}
private extension HUDSurface where SurfaceShape == Capsule {
    init(interactive: Bool) { self.init(interactive: interactive, shape: Capsule()) }
}
private struct HUDGroup: ViewModifier {
    func body(content: Content) -> some View {
        // Spacing 0 keeps the two capsules sampling one backdrop without morphing into a single blob.
        if #available(macOS 26, *) { GlassEffectContainer(spacing: 0) { content } } else { content }
    }
}
