import SweepCore
import SwiftUI

struct ConfirmSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chosen = model.selectedFindings
        let deleting = chosen.filter { $0.action != .trash }
        let trashing = chosen.filter { $0.action == .trash }
        VStack(alignment: .leading, spacing: 0) {
            Text("Free \(Format.bytes(model.selectedBytes))?")
                .font(Theme.title).foregroundStyle(Theme.text)
            Text("Sweep checks each item again right before removing it, and skips anything that changed or is in use.")
                .font(Theme.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(spacing: 0) {
                if !deleting.isEmpty {
                    PlanRow(symbol: "arrow.triangle.2.circlepath", tint: Theme.accent,
                            title: deleting.count == 1 ? "Delete 1 item that rebuilds itself" : "Delete \(deleting.count) items that rebuild themselves",
                            detail: "Apps recreate these when they need them.",
                            size: deleting.reduce(0) { $0 + $1.reclaimableSize })
                }
                if !deleting.isEmpty && !trashing.isEmpty {
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 54)
                }
                if !trashing.isEmpty {
                    PlanRow(symbol: "trash", tint: Theme.review,
                            title: "Move \(trashing.count) \(trashing.count == 1 ? "item" : "items") to the Trash",
                            detail: "You can put them back until you empty the Trash.",
                            size: trashing.reduce(0) { $0 + $1.reclaimableSize })
                }
            }
            .card()
            .padding(.top, 20)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Free \(Format.bytes(model.selectedBytes))") { model.clean() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.background)
    }
}

struct PlanRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var size: Int64

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.headline).foregroundStyle(Theme.text)
                Text(detail).font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(size)).font(Theme.rowNumber).foregroundStyle(Theme.text)
        }
        .padding(16)
    }
}

struct CleaningScreen: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Cleaning up…").font(Theme.title).foregroundStyle(Theme.text)
            Text("Checking each item one last time before removing it.")
                .font(Theme.caption).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DoneScreen: View {
    var model: AppModel
    @ViewState private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let outcome = model.outcome ?? CleanOutcome(freedBytes: 0, trashedBytes: 0, deletedCount: 0, trashedCount: 0, skipped: [], canUndo: false)
        let used = max(model.report?.usedBytes ?? 0, outcome.freedBytes)
        VStack(alignment: .leading, spacing: 0) {
            Text("Freed").font(Theme.body).foregroundStyle(Theme.secondary)
            let parts = Format.bytesParts(outcome.freedBytes)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.0).font(Theme.display)
                Text(parts.1).font(Theme.displayUnit).foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 14) {
                UsageBar(label: "Before", used: used, total: used, fill: Theme.secondary.opacity(0.55))
                UsageBar(label: "After", used: settled ? used - outcome.freedBytes : used, total: used, fill: Theme.accent)
            }
            .padding(.top, 28)

            Text(summary(outcome))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            ForEach(outcome.skipped, id: \.title) { skip in
                Label("\(skip.title): \(skip.reason)", systemImage: "exclamationmark.circle")
                    .font(Theme.caption).foregroundStyle(Theme.secondary).padding(.top, 6)
            }

            HStack(spacing: 8) {
                if outcome.canUndo && outcome.trashedCount > 0 {
                    Button("Put back from Trash") { model.undo() }.buttonStyle(QuietButtonStyle())
                }
                Spacer()
                Button("Scan again") { model.startScan() }.buttonStyle(QuietButtonStyle())
                Button("Done") { model.screen = .results }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 32)
        }
        .frame(width: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9).delay(0.2)) { settled = true }
        }
    }

    private func summary(_ o: CleanOutcome) -> String {
        var parts: [String] = []
        if o.deletedCount > 0 { parts.append(o.deletedCount == 1 ? "Deleted 1 item that rebuilds itself." : "Deleted \(o.deletedCount) items that rebuild themselves.") }
        if o.trashedCount > 0 { parts.append("Moved \(o.trashedCount) to the Trash (\(Format.bytes(o.trashedBytes))). Empty the Trash to free that space too.") }
        parts.append("If free space looks lower than this in Finder, macOS is still holding some of it in a snapshot. It's released over the next few hours.")
        return parts.joined(separator: " ")
    }
}

struct UsageBar: View {
    var label: String
    var used: Int64
    var total: Int64
    var fill: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(Theme.secondary)
                Spacer()
                Text(Format.precise(used) + " used").foregroundStyle(Theme.text).contentTransition(.numericText())
            }
            .font(Theme.number)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(fill)
                        .frame(width: geo.size.width * CGFloat(total > 0 ? Double(used) / Double(total) : 0))
                }
            }
            .frame(height: 8)
        }
    }
}
