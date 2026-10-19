import SweepCore
import SwiftUI

/// One arc of the sunburst, in turns (0...1) and ring depth (1 = innermost ring).
struct SunburstSegment: Identifiable {
    let id: String
    let name: String
    let size: Int64
    let depth: Int
    let start: Double
    let end: Double
    let bucket: Bucket?
}

enum SunburstLayout {
    /// Lays the tree out with angles proportional to allocated size. `total` lets an
    /// in-progress scan reserve the not-yet-scanned share, so arcs never jump as it grows.
    static func segments(for root: SizeNode, total: Int64? = nil, maxDepth: Int = 3) -> [SunburstSegment] {
        let denominator = Double(max(total ?? root.allocatedSize, root.allocatedSize, 1))
        var out: [SunburstSegment] = []
        func walk(_ node: SizeNode, depth: Int, start: Double) {
            var cursor = start
            for child in node.children {
                let span = Double(child.allocatedSize) / denominator
                guard span > 0.0015 else { cursor += span; continue }
                out.append(SunburstSegment(id: child.path, name: child.name, size: child.allocatedSize,
                                           depth: depth, start: cursor, end: cursor + span, bucket: child.bucket))
                if depth < maxDepth { walk(child, depth: depth + 1, start: cursor) }
                cursor += span
            }
        }
        walk(root, depth: 1, start: 0)
        return out
    }
}

struct SunburstView: View {
    var segments: [SunburstSegment]
    /// 0...1 real scan progress, drawn as a thin outer ring. nil once the scan is done.
    var progress: Double?
    /// Rotating beam while scanning; off when reduce motion is on.
    var showsBeam: Bool = false
    var centerTitle: String
    var centerSubtitle: String
    @Binding var hovered: SunburstSegment?
    /// Called when a segment is clicked; nil makes the chart look-only.
    var onSelect: ((SunburstSegment) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let rings = 3

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                TimelineView(.animation(paused: !(showsBeam && !reduceMotion))) { timeline in
                    Canvas { ctx, canvasSize in
                        draw(in: &ctx, size: canvasSize, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                // Glass hub, sized to the hole in the middle of the rings.
                Circle()
                    .fill(.clear)
                    .frame(width: radii(size: size).core * 2 - 6, height: radii(size: size).core * 2 - 6)
                    .glassEffect(.regular, in: Circle())
                VStack(spacing: 2) {
                    Text(hovered?.name ?? centerTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(hovered.map { Format.bytes($0.size) } ?? centerSubtitle)
                        .font(Theme.number)
                        .foregroundStyle(Theme.secondary)
                }
                .frame(width: size * 0.4)
                .animation(.easeOut(duration: 0.12), value: hovered?.id)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            .onTapGesture(coordinateSpace: .local) { point in
                guard let onSelect else { return }
                let origin = CGPoint(x: (geo.size.width - size) / 2, y: (geo.size.height - size) / 2)
                if let hit = segment(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y), size: size) { onSelect(hit) }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let origin = CGPoint(x: (geo.size.width - size) / 2, y: (geo.size.height - size) / 2)
                    hovered = segment(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y), size: size)
                case .ended:
                    hovered = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of your Mac's storage")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: Geometry

    private func radii(size: CGFloat) -> (core: CGFloat, ring: CGFloat, outer: CGFloat) {
        let outer = size / 2 - 10
        let core = outer * 0.3
        return (core, (outer - core) / CGFloat(rings), outer)
    }

    private func segment(at point: CGPoint, size: CGFloat) -> SunburstSegment? {
        let (core, ring, _) = radii(size: size)
        let dx = point.x - size / 2, dy = point.y - size / 2
        let r = sqrt(dx * dx + dy * dy)
        guard r > core else { return nil }
        let depth = Int((r - core) / ring) + 1
        var turn = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if turn < 0 { turn += 1 }
        return segments.last { $0.depth == depth && turn >= $0.start && turn < $0.end }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let side = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let (core, ring, outer) = radii(size: side)

        // Empty tracks first, so unscanned space reads as "not yet looked at".
        for depth in 1...rings {
            let r0 = core + ring * CGFloat(depth - 1) + 1.5, r1 = r0 + ring - 3
            ctx.fill(annulus(c, r0, r1, 0, 1), with: .color(Theme.track))
        }

        for seg in segments {
            let r0 = core + ring * CGFloat(seg.depth - 1) + 1.5
            let r1 = r0 + ring - 3
            let gap = min(0.0025, (seg.end - seg.start) * 0.2)
            let path = annulus(c, r0, r1, seg.start + gap, seg.end - gap)
            let isHovered = hovered?.id == seg.id
            let fill: Color = seg.bucket.map { Theme.color(for: $0) } ?? (seg.depth == 1 ? Theme.segmentDeep : Theme.segment)
            ctx.fill(path, with: .color(fill.opacity(isHovered ? 1 : (seg.bucket == nil ? 1 : 0.88))))
            if isHovered {
                ctx.stroke(path, with: .color(Theme.text.opacity(0.5)), lineWidth: 1.5)
            }
        }

        if let progress {
            let r = outer + 6
            var track = Path()
            track.addArc(center: c, radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(track, with: .color(Theme.track), lineWidth: 2)
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * max(0.002, progress)), clockwise: false)
            ctx.stroke(arc, with: .conicGradient(Gradient(colors: Theme.aurora + [Theme.aurora[0]]),
                                                 center: c, angle: .degrees(-90)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        if showsBeam && !reduceMotion {
            let turn = (time / 3.2).truncatingRemainder(dividingBy: 1)
            let angle = Angle.radians(turn * 2 * .pi - .pi / 2)
            let wedge = annulus(c, core, outer, turn - 0.09, turn)
            ctx.fill(wedge, with: .conicGradient(
                Gradient(stops: [.init(color: Theme.accent.opacity(0), location: 0),
                                 .init(color: Theme.accent.opacity(0.16), location: 0.09)]),
                center: c, angle: .radians((turn - 0.09) * 2 * .pi - .pi / 2)))
            var line = Path()
            line.move(to: CGPoint(x: c.x + core * cos(angle.radians), y: c.y + core * sin(angle.radians)))
            line.addLine(to: CGPoint(x: c.x + outer * cos(angle.radians), y: c.y + outer * sin(angle.radians)))
            ctx.stroke(line, with: .color(Theme.accent.opacity(0.7)), lineWidth: 1)
        }
    }

    private func annulus(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ t0: Double, _ t1: Double) -> Path {
        guard t1 > t0 else { return Path() }
        let a0 = Angle.radians(t0 * 2 * .pi - .pi / 2), a1 = Angle.radians(t1 * 2 * .pi - .pi / 2)
        var p = Path()
        p.addArc(center: c, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }

    private var accessibilitySummary: String {
        segments.filter { $0.depth == 1 }.sorted { $0.size > $1.size }.prefix(5)
            .map { "\($0.name) \(Format.bytes($0.size))" }.joined(separator: ", ")
    }
}
