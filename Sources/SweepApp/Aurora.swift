import AppKit
import SwiftUI

/// The window's backdrop: the desktop blurred behind the window (like Ghostty's
/// background-blur), a tint like its background-opacity, and the aurora on top.
struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            BehindWindowBlur()
            Theme.windowTint
            AuroraView()
        }
        .ignoresSafeArea()
        .background(TransparentWindow())
        .accessibilityHidden(true)
    }
}

/// Northern lights: soft vertical curtains of colour that drift and breathe near the top of
/// the window. Slow on purpose (cycles of 40–90 s); still when Reduce Motion is on.
struct AuroraView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Each curtain: colour index, height of its base (fraction of window), wave
    /// frequency, drift speed, phase, amplitude.
    private let curtains: [(color: Int, base: CGFloat, frequency: CGFloat, speed: Double, phase: Double, amplitude: CGFloat)] = [
        (0, 0.30, 1.6, 0.070, 0.0, 0.07),
        (1, 0.22, 2.3, -0.050, 1.7, 0.05),
        (2, 0.36, 1.2, 0.040, 3.1, 0.08),
        (3, 0.18, 2.8, -0.090, 4.4, 0.04),
        (4, 0.26, 1.9, 0.060, 5.9, 0.06),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: min(size.width, size.height) * 0.07))
                    for curtain in curtains {
                        draw(curtain, in: &layer, size: size, time: t)
                    }
                }
            }
        }
        .blendMode(scheme == .dark ? .screen : .multiply)
        .opacity(scheme == .dark ? 0.62 : 0.30)
        .allowsHitTesting(false)
    }

    private func draw(_ curtain: (color: Int, base: CGFloat, frequency: CGFloat, speed: Double, phase: Double, amplitude: CGFloat),
                      in context: inout GraphicsContext, size: CGSize, time: Double) {
        let color = Theme.aurora[curtain.color]
        let breathe = 0.75 + 0.25 * sin(time * 0.11 + curtain.phase)
        var top = Path()
        var bottom: [CGPoint] = []
        let steps = 48
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps)
            let wave = sin(Double(x * curtain.frequency * 2 * .pi) + time * curtain.speed * 2 * .pi / 6 + curtain.phase)
            let y = (curtain.base + curtain.amplitude * CGFloat(wave)) * size.height
            // Curtains hang from a wavy line: tall streaks above it, a soft fringe below.
            let height = size.height * (0.16 + 0.10 * CGFloat(sin(Double(x) * 9 + curtain.phase + time * 0.05)))
            let point = CGPoint(x: x * size.width, y: y - height)
            if i == 0 { top.move(to: point) } else { top.addLine(to: point) }
            bottom.append(CGPoint(x: x * size.width, y: y + size.height * 0.03))
        }
        for point in bottom.reversed() { top.addLine(to: point) }
        top.closeSubpath()
        let midY = curtain.base * size.height
        context.fill(top, with: .linearGradient(
            Gradient(stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color.opacity(0.55 * breathe), location: 0.55),
                .init(color: color.opacity(0.85 * breathe), location: 0.92),
                .init(color: color.opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: midY - size.height * 0.3),
            endPoint: CGPoint(x: 0, y: midY + size.height * 0.05)))
    }
}

/// NSVisualEffectView blurring whatever is behind the window.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Makes the hosting window non-opaque so the blur shows the desktop, and lets the
/// content run under the (hidden) title bar.
private struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
