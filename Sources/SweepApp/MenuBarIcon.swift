import AppKit
import SwiftUI

/// The app icon's rings and sweep beam (scripts/make-icon.swift) as a one-colour template
/// image, so macOS tints it like every other menu bar icon. The icon's coloured segments are
/// solid; its faint segments are drawn faint, the way the icon shows them.
enum MenuBarIcon {
    @MainActor static let image: NSImage = {
        let renderer = ImageRenderer(content: Glyph().frame(width: 18, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private struct Glyph: View {
        var body: some View {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Same angles as the icon, with radii spread a little so the rings stay
                // apart at 18 pt: (radius, start°, end°, solid).
                let arcs: [(CGFloat, Double, Double, Bool)] = [
                    (2.9, -90, 160, false), (2.9, 166, 262, true),
                    (5.2, -90, 40, false), (5.2, 46, 120, true), (5.2, 126, 262, false),
                    (7.5, -90, -20, true), (7.5, -14, 200, false), (7.5, 206, 262, true),
                ]
                for (radius, start, end, solid) in arcs {
                    var arc = Path()
                    arc.addArc(center: center, radius: radius, startAngle: .degrees(start),
                               endAngle: .degrees(end), clockwise: false)
                    context.stroke(arc, with: .color(.black.opacity(solid ? 1 : 0.3)), lineWidth: 1.4)
                }
                var beam = Path()
                // The icon's dark hub hides the beam's first stretch; start it just outside.
                beam.move(to: CGPoint(x: center.x, y: center.y - 1.6))
                beam.addLine(to: CGPoint(x: center.x, y: center.y - 8.8))
                context.stroke(beam, with: .color(.black), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            }
        }
    }
}
