import AppKit
import SwiftUI

struct MenuBarView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Sweep")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.text)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Free space")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Text(model.freeSpace.map(Format.bytes) ?? "Checking…")
                    .font(Theme.title)
                    .foregroundStyle(Theme.text)
                Text("Last scan: \(Format.ago(model.lastScanDate))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 6) {
                Button("Open Sweep", action: openSweep)
                    .buttonStyle(QuietButtonStyle())
                Spacer(minLength: 0)
                Button("Scan now") {
                    model.startScan()
                    openSweep()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(Theme.background)
        .onAppear { model.refreshMenuBar() }
    }

    private func openSweep() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
