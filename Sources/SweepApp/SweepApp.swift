import FoundationModels
import SwiftUI

@main
struct SweepApp: App {
    var body: some Scene {
        WindowGroup("Sweep") {
            SpikeView()
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}

/// P0 spike: proves Canvas animation and on-device model availability work in a
/// CLT-built bundle. Replaced by the welcome screen in P1.
struct SpikeView: View {
    var body: some View {
        VStack(spacing: 24) {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    for ring in 0..<5 {
                        let radius = CGFloat(30 + ring * 22)
                        let sweep = (t * (0.3 + Double(ring) * 0.15)).truncatingRemainder(dividingBy: 1)
                        var path = Path()
                        path.addArc(center: center, radius: radius,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(-90 + 360 * sweep), clockwise: false)
                        context.stroke(path, with: .color(.green.opacity(1 - Double(ring) * 0.15)),
                                       style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                    }
                }
            }
            .frame(width: 280, height: 280)
            Text("On-device model: \(modelStatus)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var modelStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: "available"
        case .unavailable(let reason): "unavailable (\(reason))"
        }
    }
}
