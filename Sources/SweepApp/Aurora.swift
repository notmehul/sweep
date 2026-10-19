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

    /// Each curtain: colour index, base line (fraction of height), wave frequency, drift
    /// speed, phase, amplitude, height. Green dominates, as in a real aurora; teal, violet and
    /// pink sit higher and thinner, like the fringes at the top of the curtains.
    private let curtains: [(color: Int, base: CGFloat, frequency: CGFloat, speed: Double, phase: Double, amplitude: CGFloat, height: CGFloat)] = [
        (0, 0.34, 1.3, 0.050, 0.0, 0.06, 0.26),
        (0, 0.26, 2.1, -0.040, 2.2, 0.05, 0.20),
        (1, 0.30, 1.7, 0.030, 4.0, 0.07, 0.16),
        (2, 0.16, 1.1, -0.025, 1.1, 0.05, 0.14),
        (3, 0.12, 2.6, 0.035, 5.3, 0.03, 0.08),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: min(size.width, size.height) * 0.018))
                    for curtain in curtains {
                        draw(curtain, in: &layer, size: size, time: t)
                    }
                }
            }
        }
        .blendMode(scheme == .dark ? .screen : .multiply)
        .opacity(scheme == .dark ? 0.9 : 0.28)
        .allowsHitTesting(false)
    }

    /// A curtain is drawn as thin vertical strips: each hangs from a slowly waving line and
    /// fades upward; their brightness varies across the width, which reads as aurora rays.
    private func draw(_ c: (color: Int, base: CGFloat, frequency: CGFloat, speed: Double, phase: Double, amplitude: CGFloat, height: CGFloat),
                      in context: inout GraphicsContext, size: CGSize, time: Double) {
        let color = Theme.aurora[c.color]
        let strips = 90
        let width = size.width / CGFloat(strips)
        for i in 0..<strips {
            let x = (CGFloat(i) + 0.5) / CGFloat(strips)
            let drift = time * c.speed
            let wave = sin(Double(x * c.frequency) * 2 * .pi + drift * 2 * .pi / 4 + c.phase)
            let baseY = (c.base + c.amplitude * CGFloat(wave)) * size.height
            // Rays: two interfering ripples across the width, slowly shifting.
            let ray = 0.55 + 0.45 * sin(Double(x) * 37 + c.phase + drift * 3) * sin(Double(x) * 11 - drift * 2 + c.phase)
            let breathe = 0.8 + 0.2 * sin(time * 0.09 + c.phase + Double(x) * 2)
            let alpha = max(0, ray) * breathe
            let top = baseY - c.height * size.height * CGFloat(0.7 + 0.3 * ray)
            let rect = CGRect(x: CGFloat(i) * width - 0.5, y: top, width: width + 1, height: baseY - top + size.height * 0.02)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color.opacity(0.35 * alpha), location: 0.6),
                    .init(color: color.opacity(0.95 * alpha), location: 0.94),
                    .init(color: color.opacity(0), location: 1),
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
    }
}

/// NSVisualEffectView blurring whatever is behind the window.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
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
