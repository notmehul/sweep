// Renders Resources/AppIcon.icns. Run: scripts/make-icon.sh
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824pt rounded square centred in 1024.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.16), Color(red: 0.05, green: 0.055, blue: 0.065)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let mint = Color(red: 0.44, green: 0.85, blue: 0.66)
                let amber = Color(red: 0.91, green: 0.69, blue: 0.29)
                let ring = Color.white.opacity(0.13)
                // (radius, width, start°, end°, colour) — three rings like the app's sunburst.
                let arcs: [(CGFloat, CGFloat, Double, Double, Color)] = [
                    (120, 54, -90, 160, ring), (120, 54, 166, 262, mint),
                    (190, 54, -90, 40, ring), (190, 54, 46, 120, amber), (190, 54, 126, 262, ring),
                    (260, 54, -90, -20, mint), (260, 54, -14, 200, ring), (260, 54, 206, 262, mint),
                ]
                for (r, w, a0, a1, color) in arcs {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .butt))
                }
                // The sweep: a soft wedge trailing a thin beam.
                var wedge = Path()
                wedge.move(to: c)
                wedge.addArc(center: c, radius: 300, startAngle: .degrees(-90 - 50), endAngle: .degrees(-90), clockwise: false)
                wedge.closeSubpath()
                ctx.fill(wedge, with: .conicGradient(Gradient(colors: [mint.opacity(0), mint.opacity(0.30)]),
                                                     center: c, angle: .degrees(-90 - 50)))
                var beam = Path()
                beam.move(to: c)
                beam.addLine(to: CGPoint(x: c.x, y: c.y - 300))
                ctx.stroke(beam, with: .color(mint), lineWidth: 10)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 62, y: c.y - 62, width: 124, height: 124)),
                         with: .color(Color(red: 0.07, green: 0.075, blue: 0.085)))
            }
            .frame(width: 824, height: 824)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage else { throw NSError(domain: "icon", code: 1) }
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}

try MainActor.assumeIsolated { try render() }
